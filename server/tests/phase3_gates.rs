//! Phase 3 acceptance checks against a real PostgreSQL database.
//!
//! These tests start the server binary, so they need the local database from
//! `server/compose.yaml`:
//!
//! ```sh
//! podman compose -f server/compose.yaml up -d postgres
//! BW_TEST_DATABASE_URL=postgres://budgetwarden:budgetwarden@127.0.0.1:54329/budgetwarden \
//!   cargo test --test phase3_gates -- --ignored --test-threads=1
//! ```

use std::{
    net::TcpListener,
    process::{Child, Command, Stdio},
    time::Duration,
};

use base64::{Engine as _, engine::general_purpose::STANDARD};
use reqwest::{Client, Response, StatusCode};
use serde_json::{Value, json};
use uuid::Uuid;

const DEV_TOKEN: &str = "local-only-dev-token-change-this";
const DEV_ACCOUNT: &str = "00000000-0000-0000-0000-000000000001";
const CURSOR_SECRET: &str = "local-only-test-cursor-secret-with-enough-bytes";

struct Server {
    child: Child,
    base: String,
}

impl Drop for Server {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

fn start_server() -> Server {
    let database_url = std::env::var("BW_TEST_DATABASE_URL")
        .expect("set BW_TEST_DATABASE_URL to the local PostgreSQL URL");
    let port = TcpListener::bind("127.0.0.1:0")
        .unwrap()
        .local_addr()
        .unwrap()
        .port();
    let listen = format!("127.0.0.1:{port}");
    let child = Command::new(env!("CARGO_BIN_EXE_bw-cloud-server"))
        .env("BW_ENV", "development")
        .env("BW_LISTEN_ADDR", &listen)
        .env("BW_DATABASE_URL", database_url)
        .env("BW_CURSOR_SECRET", CURSOR_SECRET)
        .env("BW_DEV_ACCOUNT_ID", DEV_ACCOUNT)
        .env("BW_DEV_BEARER_TOKEN", DEV_TOKEN)
        .env("BW_DEV_ENTITLEMENT", "true")
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .expect("start cloud server");
    Server {
        child,
        base: format!("http://{listen}"),
    }
}

async fn wait_ready(client: &Client, base: &str) {
    for _ in 0..100 {
        if let Ok(response) = client.get(format!("{base}/healthz")).send().await
            && response.status().is_success()
        {
            return;
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    panic!("server did not become ready");
}

fn b64(bytes: usize, fill: u8) -> String {
    STANDARD.encode(vec![fill; bytes])
}

/// A structurally valid envelope. The server never decrypts, so the bytes only
/// need the correct shape and sizes.
fn envelope(portable_id: Uuid, fill: u8) -> Value {
    json!({
        "envelope_version": 1,
        "suite": "xchacha20poly1305-x25519-v1",
        "portable_budget_id": portable_id,
        "schema_version": 2,
        "nonce": b64(24, fill),
        "ciphertext": b64(64, fill),
        "wrapped_data_key": {
            "nonce": b64(24, fill),
            "ciphertext": b64(48, fill)
        }
    })
}

struct Api {
    client: Client,
    base: String,
}

impl Api {
    fn auth(&self, builder: reqwest::RequestBuilder) -> reqwest::RequestBuilder {
        builder
            .bearer_auth(DEV_TOKEN)
            .header("Budget-Warden-Protocol", "1")
    }

    async fn create(&self, cloud_id: Uuid, key: Uuid, envelope: &Value) -> Response {
        self.auth(self.client.post(format!("{}/v1/budgets", self.base)))
            .header("Idempotency-Key", key.to_string())
            .json(&json!({ "cloud_budget_id": cloud_id, "envelope": envelope }))
            .send()
            .await
            .unwrap()
    }

    async fn replace(&self, cloud_id: Uuid, key: Uuid, etag: &str, envelope: &Value) -> Response {
        self.auth(
            self.client
                .put(format!("{}/v1/budgets/{cloud_id}", self.base)),
        )
        .header("Idempotency-Key", key.to_string())
        .header("If-Match", etag)
        .json(&json!({ "envelope": envelope }))
        .send()
        .await
        .unwrap()
    }

    async fn get(&self, cloud_id: Uuid) -> Response {
        self.auth(
            self.client
                .get(format!("{}/v1/budgets/{cloud_id}", self.base)),
        )
        .send()
        .await
        .unwrap()
    }

    async fn delete(&self, cloud_id: Uuid, key: Uuid, etag: &str) -> Response {
        self.auth(
            self.client
                .delete(format!("{}/v1/budgets/{cloud_id}", self.base)),
        )
        .header("Idempotency-Key", key.to_string())
        .header("If-Match", etag)
        .send()
        .await
        .unwrap()
    }

    async fn catalog(&self, page_token: Option<&str>) -> Value {
        let mut url = url::Url::parse(&format!("{}/v1/budgets", self.base)).unwrap();
        if let Some(token) = page_token {
            url.query_pairs_mut().append_pair("page_token", token);
        }
        self.auth(self.client.get(url))
            .send()
            .await
            .unwrap()
            .json()
            .await
            .unwrap()
    }

    async fn changes(&self, cursor: &str) -> (StatusCode, Value) {
        let url = url::Url::parse_with_params(
            &format!("{}/v1/sync/changes", self.base),
            &[("cursor", cursor)],
        )
        .unwrap();
        let response = self.auth(self.client.get(url)).send().await.unwrap();
        let status = response.status();
        (status, response.json().await.unwrap_or(Value::Null))
    }
}

fn etag_of(response: &Response) -> String {
    response
        .headers()
        .get("etag")
        .expect("etag header")
        .to_str()
        .unwrap()
        .to_owned()
}

async fn error_code(response: Response) -> String {
    let body: Value = response.json().await.unwrap();
    body["code"].as_str().unwrap_or_default().to_owned()
}

async fn setup() -> (Server, Api) {
    let server = start_server();
    let client = Client::new();
    wait_ready(&client, &server.base).await;
    let api = Api {
        client,
        base: server.base.clone(),
    };
    (server, api)
}

/// Creates a budget and returns its cloud ID, portable ID, and current ETag.
async fn create_budget(api: &Api, fill: u8) -> (Uuid, Uuid, String) {
    let cloud_id = Uuid::new_v4();
    let portable_id = Uuid::new_v4();
    let response = api
        .create(cloud_id, Uuid::new_v4(), &envelope(portable_id, fill))
        .await;
    assert!(
        response.status().is_success(),
        "create failed: {}",
        response.status()
    );
    let etag = etag_of(&response);
    (cloud_id, portable_id, etag)
}

#[tokio::test]
#[ignore = "needs BW_TEST_DATABASE_URL pointing at the local PostgreSQL"]
async fn rejects_plaintext_and_wrong_suite_bodies() {
    let (_server, api) = setup().await;
    let plaintext = json!({
        "id": Uuid::new_v4(),
        "schema_version": 2,
        "title": "Home"
    });
    let response = api.create(Uuid::new_v4(), Uuid::new_v4(), &plaintext).await;
    assert_eq!(response.status(), StatusCode::UNPROCESSABLE_ENTITY);
    assert_eq!(error_code(response).await, "invalid_snapshot");

    let mut wrong_suite = envelope(Uuid::new_v4(), 1);
    wrong_suite["suite"] = json!("plaintext");
    let response = api
        .create(Uuid::new_v4(), Uuid::new_v4(), &wrong_suite)
        .await;
    assert_eq!(response.status(), StatusCode::UNPROCESSABLE_ENTITY);
    assert_eq!(error_code(response).await, "envelope_unsupported");
}

#[tokio::test]
#[ignore = "needs BW_TEST_DATABASE_URL pointing at the local PostgreSQL"]
async fn concurrent_conditional_writes_accept_exactly_one_winner() {
    let (_server, api) = setup().await;
    let (cloud_id, portable_id, etag) = create_budget(&api, 2).await;

    let body_a = envelope(portable_id, 3);
    let body_b = envelope(portable_id, 4);
    let first = api.replace(cloud_id, Uuid::new_v4(), &etag, &body_a);
    let second = api.replace(cloud_id, Uuid::new_v4(), &etag, &body_b);
    let (first, second) = tokio::join!(first, second);

    let statuses = [first.status(), second.status()];
    let successes = statuses.iter().filter(|s| s.is_success()).count();
    assert_eq!(successes, 1, "statuses: {statuses:?}");
    let loser = if first.status().is_success() {
        second
    } else {
        first
    };
    assert_eq!(loser.status(), StatusCode::CONFLICT);
    assert_eq!(error_code(loser).await, "version_conflict");
}

#[tokio::test]
#[ignore = "needs BW_TEST_DATABASE_URL pointing at the local PostgreSQL"]
async fn retries_with_the_same_key_do_not_duplicate_budgets_or_changes() {
    let (_server, api) = setup().await;
    let cloud_id = Uuid::new_v4();
    let key = Uuid::new_v4();
    let body = envelope(Uuid::new_v4(), 5);
    let cursor = bootstrap_cursor(&api).await;

    let first = api.create(cloud_id, key, &body).await;
    assert!(first.status().is_success());
    let first_etag = etag_of(&first);
    let replay = api.create(cloud_id, key, &body).await;
    assert!(
        replay.status().is_success(),
        "replay status {}",
        replay.status()
    );
    assert_eq!(
        etag_of(&replay),
        first_etag,
        "replay must return the original version"
    );

    let different = api
        .create(cloud_id, key, &envelope(Uuid::new_v4(), 6))
        .await;
    assert_eq!(different.status(), StatusCode::CONFLICT);
    assert_eq!(error_code(different).await, "idempotency_key_reused");

    let (status, changes) = api.changes(&cursor).await;
    assert_eq!(status, StatusCode::OK, "changes body: {changes}");
    let matching = changes["changes"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|item| item["cloud_budget_id"] == json!(cloud_id))
        .count();
    assert_eq!(
        matching, 1,
        "a replayed create must not add a second change"
    );
}

async fn bootstrap_cursor(api: &Api) -> String {
    // A complete catalog scan yields a cursor that starts after everything
    // committed so far.
    let mut page_token: Option<String> = None;
    loop {
        let page = api.catalog(page_token.as_deref()).await;
        if let Some(cursor) = page["bootstrap_cursor"].as_str() {
            return cursor.to_owned();
        }
        page_token = page["next_page_token"].as_str().map(str::to_owned);
        assert!(
            page_token.is_some(),
            "catalog ended without a bootstrap cursor"
        );
    }
}

#[tokio::test]
#[ignore = "needs BW_TEST_DATABASE_URL pointing at the local PostgreSQL"]
async fn bootstrap_then_changes_does_not_miss_updates() {
    let (_server, api) = setup().await;
    let cursor = bootstrap_cursor(&api).await;

    let (cloud_id, portable_id, etag) = create_budget(&api, 7).await;
    let updated = api
        .replace(cloud_id, Uuid::new_v4(), &etag, &envelope(portable_id, 8))
        .await;
    assert!(updated.status().is_success());
    let expected_etag = etag_of(&updated);

    let (status, changes) = api.changes(&cursor).await;
    assert_eq!(status, StatusCode::OK, "changes body: {changes}");
    let entries: Vec<&Value> = changes["changes"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|item| item["cloud_budget_id"] == json!(cloud_id))
        .collect();
    assert!(
        !entries.is_empty(),
        "the change feed missed the new budget: {changes}"
    );
    let latest = entries.last().unwrap();
    assert_eq!(
        latest["server_version"],
        json!(expected_etag.trim_matches('"'))
    );
}

#[tokio::test]
#[ignore = "needs BW_TEST_DATABASE_URL pointing at the local PostgreSQL"]
async fn deleted_budgets_stay_deleted_and_reject_writes() {
    let (_server, api) = setup().await;
    let (cloud_id, portable_id, etag) = create_budget(&api, 9).await;

    let deleted = api.delete(cloud_id, Uuid::new_v4(), &etag).await;
    assert!(
        deleted.status().is_success(),
        "delete status {}",
        deleted.status()
    );

    let read = api.get(cloud_id).await;
    assert_eq!(read.status(), StatusCode::GONE);
    assert_eq!(error_code(read).await, "resource_deleted");

    let resurrect = api
        .replace(cloud_id, Uuid::new_v4(), &etag, &envelope(portable_id, 10))
        .await;
    assert_eq!(resurrect.status(), StatusCode::GONE);
}

#[tokio::test]
#[ignore = "needs BW_TEST_DATABASE_URL pointing at the local PostgreSQL"]
async fn get_returns_the_envelope_unchanged_with_a_strong_etag() {
    let (_server, api) = setup().await;
    let portable_id = Uuid::new_v4();
    let cloud_id = Uuid::new_v4();
    let body = envelope(portable_id, 11);
    let created = api.create(cloud_id, Uuid::new_v4(), &body).await;
    assert!(created.status().is_success());

    let read = api.get(cloud_id).await;
    assert_eq!(read.status(), StatusCode::OK);
    let etag = etag_of(&read);
    assert!(etag.starts_with('"') && etag.ends_with('"'));
    let stored: Value = read.json().await.unwrap();
    assert_eq!(stored["envelope"]["ciphertext"], body["ciphertext"]);
    assert_eq!(stored["envelope"]["portable_budget_id"], json!(portable_id));
    assert!(
        stored.get("title").is_none(),
        "titles must not leave the ciphertext"
    );
}

async fn insert_second_account(database_url: &str, token: &str) -> Uuid {
    let pool = sqlx::PgPool::connect(database_url).await.unwrap();
    let account_id = Uuid::new_v4();
    let device_id = Uuid::new_v4();
    let token_digest = sha256(token.as_bytes());
    let refresh_digest = sha256(Uuid::new_v4().as_bytes());
    let mut tx = pool.begin().await.unwrap();
    sqlx::query("INSERT INTO accounts (id) VALUES ($1)")
        .bind(account_id)
        .execute(&mut *tx)
        .await
        .unwrap();
    sqlx::query("INSERT INTO devices (account_id, device_id, platform) VALUES ($1, $2, 'macos')")
        .bind(account_id)
        .bind(device_id)
        .execute(&mut *tx)
        .await
        .unwrap();
    sqlx::query(
        "INSERT INTO sessions (id, account_id, device_id, access_token_hash, refresh_token_hash, \
         refresh_family_id, access_expires_at, refresh_expires_at) \
         VALUES ($1, $2, $3, $4, $5, $6, now() + interval '1 hour', now() + interval '1 day')",
    )
    .bind(Uuid::new_v4())
    .bind(account_id)
    .bind(device_id)
    .bind(token_digest.to_vec())
    .bind(refresh_digest.to_vec())
    .bind(Uuid::new_v4())
    .execute(&mut *tx)
    .await
    .unwrap();
    sqlx::query(
        "INSERT INTO entitlements (account_id, state, can_write) VALUES ($1, 'active', true)",
    )
    .bind(account_id)
    .execute(&mut *tx)
    .await
    .unwrap();
    tx.commit().await.unwrap();
    account_id
}

fn sha256(bytes: &[u8]) -> [u8; 32] {
    use sha2::{Digest, Sha256};
    Sha256::digest(bytes).into()
}

#[tokio::test]
#[ignore = "needs BW_TEST_DATABASE_URL pointing at the local PostgreSQL"]
async fn other_accounts_cannot_see_or_write_a_budget() {
    let database_url = std::env::var("BW_TEST_DATABASE_URL").unwrap();
    let (_server, api) = setup().await;
    let (cloud_id, portable_id, etag) = create_budget(&api, 12).await;

    let other_token = format!("other-account-test-token-{}", Uuid::new_v4());
    let other_account = insert_second_account(&database_url, &other_token).await;
    let other = Api {
        client: Client::new(),
        base: api.base.clone(),
    };
    let other_auth = |builder: reqwest::RequestBuilder| {
        builder
            .bearer_auth(&other_token)
            .header("Budget-Warden-Protocol", "1")
    };

    let read = other_auth(
        other
            .client
            .get(format!("{}/v1/budgets/{cloud_id}", other.base)),
    )
    .send()
    .await
    .unwrap();
    assert_eq!(
        read.status(),
        StatusCode::NOT_FOUND,
        "foreign reads must look missing"
    );
    assert_eq!(error_code(read).await, "not_found");

    let write = other_auth(
        other
            .client
            .put(format!("{}/v1/budgets/{cloud_id}", other.base)),
    )
    .header("Idempotency-Key", Uuid::new_v4().to_string())
    .header("If-Match", etag.as_str())
    .json(&json!({ "envelope": envelope(portable_id, 13) }))
    .send()
    .await
    .unwrap();
    assert_eq!(write.status(), StatusCode::NOT_FOUND);

    let catalog: Value = other_auth(other.client.get(format!("{}/v1/budgets", other.base)))
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();
    let listed = catalog["items"]
        .as_array()
        .map(|items| {
            items
                .iter()
                .any(|item| item["cloud_budget_id"] == json!(cloud_id))
        })
        .unwrap_or(false);
    assert!(
        !listed,
        "the foreign catalog must not list the budget: {catalog}"
    );

    let pool = sqlx::PgPool::connect(&database_url).await.unwrap();
    sqlx::query("DELETE FROM accounts WHERE id = $1")
        .bind(other_account)
        .execute(&pool)
        .await
        .unwrap();
}

#[tokio::test]
#[ignore = "needs BW_TEST_DATABASE_URL pointing at the local PostgreSQL"]
async fn expired_change_cursor_requires_a_full_rescan() {
    let database_url = std::env::var("BW_TEST_DATABASE_URL").unwrap();
    let (_server, api) = setup().await;
    let old_cursor = bootstrap_cursor(&api).await;
    let _ = create_budget(&api, 14).await;

    // Simulate retention pruning: everything before the current sequence is gone.
    let pool = sqlx::PgPool::connect(&database_url).await.unwrap();
    sqlx::query("UPDATE accounts SET retained_change_floor = next_change_seq WHERE id = $1")
        .bind(Uuid::parse_str(DEV_ACCOUNT).unwrap())
        .execute(&pool)
        .await
        .unwrap();

    let (status, body) = api.changes(&old_cursor).await;
    assert!(!status.is_success(), "expired cursor was accepted: {body}");
    assert_eq!(body["code"], json!("cursor_expired"), "body: {body}");

    // A fresh bootstrap still works after the floor moves.
    let fresh = bootstrap_cursor(&api).await;
    let (status, _) = api.changes(&fresh).await;
    assert_eq!(status, StatusCode::OK);
}
