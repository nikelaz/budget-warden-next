//! Billing and sign-in limit checks against a real PostgreSQL database.
//!
//! Run with the same database as the Phase 3 gates:
//!
//! ```sh
//! BW_TEST_DATABASE_URL=postgres://budgetwarden:budgetwarden@127.0.0.1:54329/budgetwarden \
//!   cargo test --test billing_gates -- --ignored --test-threads=1
//! ```

use std::{
    net::TcpListener,
    process::{Child, Command, Stdio},
    time::Duration,
};

use chrono::{DateTime, Duration as ChronoDuration, Utc};
use hmac::{Hmac, Mac};
use reqwest::{Client, Response, StatusCode};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use uuid::Uuid;

const DEV_TOKEN: &str = "local-only-dev-token-change-this";
const DEV_ACCOUNT: &str = "00000000-0000-0000-0000-000000000001";
const CURSOR_SECRET: &str = "local-only-test-cursor-secret-with-enough-bytes";
const STRIPE_SECRET: &str = "whsec_test_secret_for_gates";

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

fn database_url() -> String {
    std::env::var("BW_TEST_DATABASE_URL")
        .expect("set BW_TEST_DATABASE_URL to the local PostgreSQL URL")
}

fn start_server() -> Server {
    let port = TcpListener::bind("127.0.0.1:0")
        .unwrap()
        .local_addr()
        .unwrap()
        .port();
    let listen = format!("127.0.0.1:{port}");
    let child = Command::new(env!("CARGO_BIN_EXE_bw-cloud-server"))
        .env("BW_ENV", "development")
        .env("BW_LISTEN_ADDR", &listen)
        .env("BW_DATABASE_URL", database_url())
        .env("BW_CURSOR_SECRET", CURSOR_SECRET)
        .env("BW_DEV_ACCOUNT_ID", DEV_ACCOUNT)
        .env("BW_DEV_BEARER_TOKEN", DEV_TOKEN)
        .env("BW_DEV_ENTITLEMENT", "true")
        .env("BW_STRIPE_WEBHOOK_SECRET", STRIPE_SECRET)
        .env("BW_AUTH_RATE_LIMIT_PER_MINUTE", "5")
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .expect("start cloud server");
    Server {
        child,
        base: format!("http://{listen}"),
    }
}

async fn setup() -> (Server, Client) {
    let server = start_server();
    let client = Client::new();
    for _ in 0..100 {
        if let Ok(response) = client.get(format!("{}/healthz", server.base)).send().await
            && response.status().is_success()
        {
            return (server, client);
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    panic!("server did not become ready");
}

fn sha256(bytes: &[u8]) -> [u8; 32] {
    Sha256::digest(bytes).into()
}

/// Creates an account with a device, a session for `token`, and optionally an
/// entitlement. Returns the account ID.
async fn insert_account(token: &str, entitled: bool) -> Uuid {
    let pool = sqlx::PgPool::connect(&database_url()).await.unwrap();
    let account_id = Uuid::new_v4();
    let device_id = Uuid::new_v4();
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
    .bind(sha256(token.as_bytes()).to_vec())
    .bind(sha256(Uuid::new_v4().as_bytes()).to_vec())
    .bind(Uuid::new_v4())
    .execute(&mut *tx)
    .await
    .unwrap();
    if entitled {
        sqlx::query(
            "INSERT INTO entitlements (account_id, state, can_write) VALUES ($1, 'active', true)",
        )
        .bind(account_id)
        .execute(&mut *tx)
        .await
        .unwrap();
    }
    tx.commit().await.unwrap();
    account_id
}

async fn delete_account(account_id: Uuid) {
    let pool = sqlx::PgPool::connect(&database_url()).await.unwrap();
    sqlx::query("DELETE FROM accounts WHERE id = $1")
        .bind(account_id)
        .execute(&pool)
        .await
        .unwrap();
}

async fn entitlement_state(account_id: Uuid) -> Option<(String, bool)> {
    let pool = sqlx::PgPool::connect(&database_url()).await.unwrap();
    sqlx::query_as::<_, (String, bool)>(
        "SELECT state, can_write FROM entitlements WHERE account_id = $1",
    )
    .bind(account_id)
    .fetch_optional(&pool)
    .await
    .unwrap()
}

fn stripe_signature(secret: &str, timestamp: i64, body: &[u8]) -> String {
    let mut mac = Hmac::<Sha256>::new_from_slice(secret.as_bytes()).unwrap();
    mac.update(timestamp.to_string().as_bytes());
    mac.update(b".");
    mac.update(body);
    let digest = mac.finalize().into_bytes();
    let hex: String = digest.iter().map(|byte| format!("{byte:02x}")).collect();
    format!("t={timestamp},v1={hex}")
}

fn stripe_event(
    event_id: &str,
    occurred_at: DateTime<Utc>,
    status: &str,
    account_id: Uuid,
    subscription: &str,
) -> Value {
    let ended_at = (status == "canceled").then_some(occurred_at.timestamp());
    json!({
        "id": event_id,
        "type": "customer.subscription.updated",
        "created": occurred_at.timestamp(),
        "data": {
            "object": {
                "id": subscription,
                "status": status,
                "metadata": { "budget_warden_account_id": account_id },
                "current_period_end": (occurred_at + ChronoDuration::days(30)).timestamp(),
                "ended_at": ended_at,
                "cancel_at_period_end": false
            }
        }
    })
}

async fn post_stripe(
    client: &Client,
    base: &str,
    event: &Value,
    signature_secret: &str,
) -> Response {
    let body = serde_json::to_vec(event).unwrap();
    let signature = stripe_signature(signature_secret, Utc::now().timestamp(), &body);
    client
        .post(format!("{base}/v1/billing/stripe/webhook"))
        .header("Stripe-Signature", signature)
        .header("Content-Type", "application/json")
        .body(body)
        .send()
        .await
        .unwrap()
}

#[tokio::test]
#[ignore = "needs BW_TEST_DATABASE_URL pointing at the local PostgreSQL"]
async fn stripe_webhooks_grant_update_and_end_access() {
    let (server, client) = setup().await;
    let account = insert_account(&format!("stripe-token-{}", Uuid::new_v4()), false).await;
    let subscription = format!("sub_{}", Uuid::new_v4().simple());
    let now = Utc::now();

    let activated = stripe_event(
        &format!("evt_{}", Uuid::new_v4()),
        now,
        "active",
        account,
        &subscription,
    );
    let response = post_stripe(&client, &server.base, &activated, STRIPE_SECRET).await;
    assert_eq!(response.status(), StatusCode::OK);
    assert_eq!(
        entitlement_state(account).await,
        Some(("active".to_owned(), true))
    );

    // Redelivery of the same event is acknowledged and changes nothing.
    let duplicate = post_stripe(&client, &server.base, &activated, STRIPE_SECRET).await;
    assert_eq!(duplicate.status(), StatusCode::OK);
    let body: Value = duplicate.json().await.unwrap();
    assert_eq!(body["status"], json!("duplicate"));

    // An older event cannot overwrite a newer state.
    let stale = stripe_event(
        &format!("evt_{}", Uuid::new_v4()),
        now - ChronoDuration::hours(1),
        "canceled",
        account,
        &subscription,
    );
    assert_eq!(
        post_stripe(&client, &server.base, &stale, STRIPE_SECRET)
            .await
            .status(),
        StatusCode::OK
    );
    assert_eq!(
        entitlement_state(account).await,
        Some(("active".to_owned(), true))
    );

    // A newer cancellation ends write access and keeps the read window.
    let canceled = stripe_event(
        &format!("evt_{}", Uuid::new_v4()),
        now + ChronoDuration::minutes(1),
        "canceled",
        account,
        &subscription,
    );
    assert_eq!(
        post_stripe(&client, &server.base, &canceled, STRIPE_SECRET)
            .await
            .status(),
        StatusCode::OK
    );
    assert_eq!(
        entitlement_state(account).await,
        Some(("expired".to_owned(), false))
    );

    delete_account(account).await;
}

#[tokio::test]
#[ignore = "needs BW_TEST_DATABASE_URL pointing at the local PostgreSQL"]
async fn stripe_webhooks_with_bad_signatures_change_nothing() {
    let (server, client) = setup().await;
    let account = insert_account(&format!("stripe-token-{}", Uuid::new_v4()), false).await;
    let event = stripe_event(
        &format!("evt_{}", Uuid::new_v4()),
        Utc::now(),
        "active",
        account,
        &format!("sub_{}", Uuid::new_v4().simple()),
    );
    let response = post_stripe(&client, &server.base, &event, "wrong-secret").await;
    assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
    let body: Value = response.json().await.unwrap();
    assert_eq!(body["code"], json!("invalid_webhook_signature"));
    assert_eq!(entitlement_state(account).await, None);

    let unsigned = client
        .post(format!("{}/v1/billing/stripe/webhook", server.base))
        .body(serde_json::to_vec(&event).unwrap())
        .send()
        .await
        .unwrap();
    assert_eq!(unsigned.status(), StatusCode::UNAUTHORIZED);
    delete_account(account).await;
}

#[tokio::test]
#[ignore = "needs BW_TEST_DATABASE_URL pointing at the local PostgreSQL"]
async fn a_subscription_cannot_move_to_another_account() {
    let (server, client) = setup().await;
    let owner = insert_account(&format!("owner-token-{}", Uuid::new_v4()), false).await;
    let other = insert_account(&format!("other-token-{}", Uuid::new_v4()), false).await;
    let subscription = format!("sub_{}", Uuid::new_v4().simple());

    let owned = stripe_event(
        &format!("evt_{}", Uuid::new_v4()),
        Utc::now(),
        "active",
        owner,
        &subscription,
    );
    assert_eq!(
        post_stripe(&client, &server.base, &owned, STRIPE_SECRET)
            .await
            .status(),
        StatusCode::OK
    );

    // A later event naming a different account is acknowledged but not applied.
    let claimed = stripe_event(
        &format!("evt_{}", Uuid::new_v4()),
        Utc::now() + ChronoDuration::minutes(1),
        "canceled",
        other,
        &subscription,
    );
    assert_eq!(
        post_stripe(&client, &server.base, &claimed, STRIPE_SECRET)
            .await
            .status(),
        StatusCode::OK
    );
    assert_eq!(
        entitlement_state(owner).await,
        Some(("active".to_owned(), true))
    );
    assert_eq!(entitlement_state(other).await, None);

    delete_account(owner).await;
    delete_account(other).await;
}

#[tokio::test]
#[ignore = "needs BW_TEST_DATABASE_URL pointing at the local PostgreSQL"]
async fn checkout_requires_a_session_and_refuses_duplicate_subscriptions() {
    let (server, client) = setup().await;
    let unauthenticated = client
        .post(format!("{}/v1/billing/stripe/checkout", server.base))
        .header("Budget-Warden-Protocol", "1")
        .send()
        .await
        .unwrap();
    assert_eq!(unauthenticated.status(), StatusCode::UNAUTHORIZED);

    let token = format!("checkout-token-{}", Uuid::new_v4());
    let entitled = insert_account(&token, true).await;
    let response = client
        .post(format!("{}/v1/billing/stripe/checkout", server.base))
        .bearer_auth(&token)
        .header("Budget-Warden-Protocol", "1")
        .send()
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::CONFLICT);
    let body: Value = response.json().await.unwrap();
    assert_eq!(body["code"], json!("entitlement_already_active"));
    delete_account(entitled).await;
}

#[tokio::test]
#[ignore = "needs BW_TEST_DATABASE_URL pointing at the local PostgreSQL"]
async fn sign_in_routes_are_rate_limited_per_client() {
    let (server, client) = setup().await;
    let mut limited = None;
    for _ in 0..12 {
        let response = client
            .post(format!("{}/v1/sessions/refresh", server.base))
            .header("Budget-Warden-Protocol", "1")
            .json(&json!({}))
            .send()
            .await
            .unwrap();
        if response.status() == StatusCode::TOO_MANY_REQUESTS {
            limited = Some(response);
            break;
        }
    }
    let response = limited.expect("the limit must trip within 12 requests");
    assert_eq!(response.headers().get("retry-after").unwrap(), "60");
    let body: Value = response.json().await.unwrap();
    assert_eq!(body["code"], json!("rate_limited"));
}

#[tokio::test]
#[ignore = "needs BW_TEST_DATABASE_URL pointing at the local PostgreSQL"]
async fn dev_account_entitlement_is_not_overwritten_by_webhooks() {
    let (server, client) = setup().await;
    let event = stripe_event(
        &format!("evt_{}", Uuid::new_v4()),
        Utc::now(),
        "canceled",
        Uuid::parse_str(DEV_ACCOUNT).unwrap(),
        &format!("sub_{}", Uuid::new_v4().simple()),
    );
    assert_eq!(
        post_stripe(&client, &server.base, &event, STRIPE_SECRET)
            .await
            .status(),
        StatusCode::OK
    );
    let state = entitlement_state(Uuid::parse_str(DEV_ACCOUNT).unwrap()).await;
    assert_eq!(state, Some(("active".to_owned(), true)));
}
