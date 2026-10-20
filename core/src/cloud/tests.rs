//! End-to-end tests of Google Drive budgets against an in-memory Drive.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use uuid::Uuid;

use super::drive::{API_ROOT, BUDGET_MIME_TYPE, UPLOAD_ROOT};
use super::http::{BWHttpClient, BWHttpRequest, BWHttpResponse, query_pairs};
use super::oauth::{REVOCATION_ENDPOINT, TOKEN_ENDPOINT};
use super::*;
use crate::app_state::initialize_core;
use crate::codec::{decode_budget, encode_budget};
use crate::domain;
use crate::models::{BWBudget, BWCategory, BWCategoryType, BWMoneyAmount, BWTransaction, BWDate};
use crate::templates::budget_from_template_id;

// MARK: Fake Drive

#[derive(Clone, Debug)]
struct FakeFile {
    name: String,
    mime_type: String,
    owner: String,
    parents: Vec<String>,
    content: String,
    version: u64,
    app_properties: Value,
    /// (permission id, email, role)
    permissions: Vec<(String, String, String)>,
    trashed: bool,
}

#[derive(Default)]
struct FakeDriveState {
    files: BTreeMap<String, FakeFile>,
    next_id: u64,
    /// access token -> email
    access_tokens: BTreeMap<String, String>,
    /// refresh token -> email
    refresh_tokens: BTreeMap<String, String>,
    /// authorization code -> (email, code challenge)
    codes: BTreeMap<String, (String, String)>,
    downloads: usize,
    uploads: usize,
    notifications: Vec<String>,
    requests: Vec<String>,
}

#[derive(Clone, Default)]
struct FakeDrive {
    state: Arc<Mutex<FakeDriveState>>,
}

fn response(status: i32, body: Value) -> BWHttpResponse {
    BWHttpResponse {
        status,
        headers: vec![],
        body: body.to_string(),
    }
}

fn error(status: i32, message: &str) -> BWHttpResponse {
    response(status, json!({ "error": { "code": status, "message": message } }))
}

impl FakeDrive {
    fn new_id(state: &mut FakeDriveState, prefix: &str) -> String {
        state.next_id += 1;
        format!("{prefix}{}", state.next_id)
    }

    /// Lets `email` complete an OAuth flow whose authorization URL was `url`.
    fn approve(&self, url: &str, email: &str) -> String {
        let pairs = query_pairs(url);
        let get = |name: &str| pairs.iter().find(|(k, _)| k == name).unwrap().1.clone();
        let code = format!("code-{}", Uuid::new_v4().simple());
        self.state
            .lock()
            .unwrap()
            .codes
            .insert(code.clone(), (email.to_string(), get("code_challenge")));
        format!("{}?state={}&code={}", get("redirect_uri"), get("state"), code)
    }

    fn expire_access_tokens(&self) {
        self.state.lock().unwrap().access_tokens.clear();
    }

    fn revoke_refresh_tokens(&self) {
        self.state.lock().unwrap().refresh_tokens.clear();
    }

    fn file(&self, id: &str) -> FakeFile {
        self.state.lock().unwrap().files[id].clone()
    }

    fn counts(&self) -> (usize, usize) {
        let state = self.state.lock().unwrap();
        (state.downloads, state.uploads)
    }

    fn metadata(id: &str, file: &FakeFile, user: &str) -> Value {
        let role = Self::role(file, user).unwrap_or_default();
        json!({
            "id": id,
            "name": file.name,
            "mimeType": file.mime_type,
            "version": file.version.to_string(),
            "modifiedTime": format!("2026-10-{:02}T00:00:00Z", (file.version % 28) + 1),
            "ownedByMe": file.owner == user,
            "shared": !file.permissions.is_empty(),
            "trashed": file.trashed,
            "owners": [{ "displayName": file.owner.split('@').next(), "emailAddress": file.owner }],
            "sharingUser": { "emailAddress": file.owner },
            "capabilities": { "canEdit": role == "owner" || role == "writer", "canShare": role == "owner" || role == "writer" },
        })
    }

    fn role(file: &FakeFile, user: &str) -> Option<String> {
        if file.owner == user {
            return Some("owner".to_string());
        }
        file.permissions
            .iter()
            .find(|(_, email, _)| email == user)
            .map(|(_, _, role)| role.clone())
    }

    fn handle(&self, request: BWHttpRequest) -> BWHttpResponse {
        let mut state = self.state.lock().unwrap();
        state.requests.push(format!("{} {}", request.method, request.url));
        let path = request.url.split('?').next().unwrap().to_string();
        let query: BTreeMap<String, String> = query_pairs(&request.url).into_iter().collect();
        let body = request.body.clone().unwrap_or_default();

        if path == TOKEN_ENDPOINT {
            let form: BTreeMap<String, String> = query_pairs(&format!("?{body}")).into_iter().collect();
            assert_eq!(form.get("client_id").map(String::as_str), Some("test-client"));
            let email = match form["grant_type"].as_str() {
                "authorization_code" => {
                    let Some((email, challenge)) = state.codes.remove(&form["code"]) else {
                        return response(400, json!({ "error": "invalid_grant" }));
                    };
                    let digest = Sha256::digest(form["code_verifier"].as_bytes());
                    assert_eq!(super::oauth::code_challenge(&form["code_verifier"]), challenge);
                    assert_eq!(digest.len(), 32);
                    email
                }
                "refresh_token" => match state.refresh_tokens.get(&form["refresh_token"]) {
                    Some(email) => email.clone(),
                    None => return response(400, json!({ "error": "invalid_grant" })),
                },
                other => panic!("unexpected grant {other}"),
            };
            let access = format!("at-{}", Uuid::new_v4().simple());
            let refresh = format!("rt-{email}");
            state.access_tokens.insert(access.clone(), email.clone());
            state.refresh_tokens.insert(refresh.clone(), email);
            return response(200, json!({ "access_token": access, "expires_in": 3599, "refresh_token": refresh }));
        }
        if path == REVOCATION_ENDPOINT {
            return response(200, json!({}));
        }

        let token = request
            .headers
            .iter()
            .find(|header| header.name == "Authorization")
            .and_then(|header| header.value.strip_prefix("Bearer "))
            .unwrap_or("");
        let Some(user) = state.access_tokens.get(token).cloned() else {
            return error(401, "Invalid Credentials");
        };

        if path == format!("{API_ROOT}/about") {
            return response(200, json!({ "user": { "displayName": user.split('@').next(), "emailAddress": user } }));
        }

        if path == format!("{API_ROOT}/files") && request.method == "GET" {
            let q = &query["q"];
            let files: Vec<Value> = state
                .files
                .iter()
                .filter(|(_, file)| !file.trashed && Self::role(file, &user).is_some())
                .filter(|(_, file)| {
                    if q.contains("google-apps.folder") {
                        file.mime_type == "application/vnd.google-apps.folder" && q.contains(&format!("name = '{}'", file.name))
                    } else {
                        assert!(q.contains(BUDGET_MIME_TYPE));
                        file.mime_type == BUDGET_MIME_TYPE
                    }
                })
                .map(|(id, file)| Self::metadata(id, file, &user))
                .collect();
            return response(200, json!({ "files": files }));
        }

        if path == format!("{API_ROOT}/files") && request.method == "POST" {
            let metadata: Value = serde_json::from_str(&body).unwrap();
            let id = Self::new_id(&mut state, "folder");
            state.files.insert(
                id.clone(),
                FakeFile {
                    name: metadata["name"].as_str().unwrap().to_string(),
                    mime_type: metadata["mimeType"].as_str().unwrap().to_string(),
                    owner: user.clone(),
                    parents: vec!["root".into()],
                    content: String::new(),
                    version: 1,
                    app_properties: json!({}),
                    permissions: vec![],
                    trashed: false,
                },
            );
            return response(200, json!({ "id": id }));
        }

        if path == format!("{UPLOAD_ROOT}/files") && request.method == "POST" {
            assert_eq!(query["uploadType"], "multipart");
            let content_type = request.headers.iter().find(|h| h.name == "Content-Type").unwrap().value.clone();
            let boundary = content_type.split("boundary=").nth(1).unwrap().to_string();
            let parts: Vec<&str> = body.split(&format!("--{boundary}")).collect();
            let metadata: Value = serde_json::from_str(parts[1].split("\r\n\r\n").nth(1).unwrap().trim()).unwrap();
            let content = parts[2].split_once("\r\n\r\n").unwrap().1.trim_end_matches("\r\n").to_string();
            let parent = metadata["parents"][0].as_str().unwrap().to_string();
            if !state.files.contains_key(&parent) {
                return error(404, "File not found: parent");
            }
            let id = Self::new_id(&mut state, "file");
            let file = FakeFile {
                name: metadata["name"].as_str().unwrap().to_string(),
                mime_type: metadata["mimeType"].as_str().unwrap().to_string(),
                owner: user.clone(),
                parents: vec![parent],
                content,
                version: 1,
                app_properties: metadata["appProperties"].clone(),
                permissions: vec![],
                trashed: false,
            };
            let answer = Self::metadata(&id, &file, &user);
            state.files.insert(id, file);
            state.uploads += 1;
            return response(200, answer);
        }

        let rest = path
            .strip_prefix(&format!("{API_ROOT}/files/"))
            .or_else(|| path.strip_prefix(&format!("{UPLOAD_ROOT}/files/")))
            .unwrap_or_else(|| panic!("unexpected request {path}"))
            .to_string();
        let mut segments = rest.split('/');
        let id = segments.next().unwrap().to_string();
        let Some(file) = state.files.get(&id).cloned() else {
            return error(404, "File not found");
        };
        let Some(role) = Self::role(&file, &user) else {
            return error(404, "File not found");
        };

        match (request.method.as_str(), segments.next(), segments.next()) {
            ("GET", None, None) if query.get("alt").map(String::as_str) == Some("media") => {
                state.downloads += 1;
                BWHttpResponse { status: 200, headers: vec![], body: file.content }
            }
            ("GET", None, None) => response(200, Self::metadata(&id, &file, &user)),
            ("PATCH", None, None) => {
                assert!(path.starts_with(UPLOAD_ROOT));
                if role != "owner" && role != "writer" {
                    return error(403, "The user does not have sufficient permissions for this file.");
                }
                let file = state.files.get_mut(&id).unwrap();
                file.content = body;
                file.version += 1;
                let answer = Self::metadata(&id, file, &user);
                state.uploads += 1;
                response(200, answer)
            }
            ("POST", Some("permissions"), None) => {
                if role != "owner" && role != "writer" {
                    return error(403, "Insufficient permissions");
                }
                let permission: Value = serde_json::from_str(&body).unwrap();
                assert_eq!(query["sendNotificationEmail"], "true");
                let permission_id = Self::new_id(&mut state, "perm");
                let email = permission["emailAddress"].as_str().unwrap().to_string();
                let role = permission["role"].as_str().unwrap().to_string();
                state.notifications.push(email.clone());
                let file = state.files.get_mut(&id).unwrap();
                file.permissions.push((permission_id.clone(), email.clone(), role.clone()));
                file.version += 1;
                response(200, json!({ "id": permission_id, "type": "user", "role": role, "emailAddress": email }))
            }
            ("GET", Some("permissions"), None) => {
                let mut permissions = vec![json!({ "id": "owner", "type": "user", "role": "owner", "emailAddress": file.owner })];
                permissions.extend(file.permissions.iter().map(|(pid, email, role)| {
                    json!({ "id": pid, "type": "user", "role": role, "emailAddress": email })
                }));
                response(200, json!({ "permissions": permissions }))
            }
            ("DELETE", Some("permissions"), Some(permission_id)) => {
                let permission_id = permission_id.to_string();
                let file = state.files.get_mut(&id).unwrap();
                file.permissions.retain(|(pid, _, _)| *pid != permission_id);
                BWHttpResponse { status: 204, headers: vec![], body: String::new() }
            }
            other => panic!("unexpected request {other:?} {path}"),
        }
    }
}

impl BWHttpClient for FakeDrive {
    fn execute(&self, request: BWHttpRequest) -> Result<BWHttpResponse, String> {
        Ok(self.handle(request))
    }
}

#[derive(Clone, Default)]
struct MemoryCredentials(Arc<Mutex<Option<String>>>);

impl BWGoogleCredentialStore for MemoryCredentials {
    fn load_credentials(&self) -> Option<String> {
        self.0.lock().unwrap().clone()
    }
    fn save_credentials(&self, credentials: String) -> Result<(), String> {
        *self.0.lock().unwrap() = Some(credentials);
        Ok(())
    }
    fn delete_credentials(&self) {
        *self.0.lock().unwrap() = None;
    }
}

// MARK: Helpers

struct Device {
    drive: BWGoogleDrive,
    credentials: MemoryCredentials,
    directory: PathBuf,
}

impl Drop for Device {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.directory);
    }
}

fn device(server: &FakeDrive) -> Device {
    let _ = initialize_core(Uuid::from_u128(0xC10D));
    let directory = std::env::temp_dir().join(format!("bw-cloud-test-{}", Uuid::new_v4().simple()));
    let drive = BWGoogleDrive::new(BWGoogleDriveConfig {
        client_id: "test-client".into(),
        client_secret: Some("secret".into()),
        cache_directory: directory.to_string_lossy().into_owned(),
        folder_name: "Budget Warden".into(),
    });
    let credentials = MemoryCredentials::default();
    drive.connect(Box::new(server.clone()), Box::new(credentials.clone()));
    Device { drive, credentials, directory }
}

fn signed_in(server: &FakeDrive, email: &str) -> Device {
    let device = device(server);
    let request = device.drive.begin_sign_in("http://127.0.0.1:4567".into()).unwrap();
    let callback = server.approve(&request.authorization_url, email);
    let account = device.drive.complete_sign_in(callback).unwrap();
    assert_eq!(account.email.as_deref(), Some(email));
    device
}

fn new_budget_json(title: &str) -> String {
    encode_budget(&budget_from_template_id("basic-monthly".into(), title.into()).unwrap()).unwrap()
}

fn read_budget(path: &str) -> BWBudget {
    decode_budget(&std::fs::read_to_string(path).unwrap(), path.to_string()).unwrap()
}

/// Edits a working copy the way the apps save: merge with disk, then write.
fn app_edit(path: &str, edit: impl FnOnce(BWBudget) -> BWBudget) {
    let on_disk = read_budget(path);
    let edited = edit(on_disk.clone()).update_actuals().unwrap();
    let merged = domain::merge_budget_for_save(edited, on_disk).unwrap();
    std::fs::write(path, encode_budget(&merged).unwrap()).unwrap();
}

fn add_transaction(budget: BWBudget, title: &str, cents: i64) -> BWBudget {
    let category = budget
        .categories
        .iter()
        .find(|category| category.category_type == BWCategoryType::Expenses)
        .unwrap()
        .id;
    domain::create_transaction(
        budget,
        category,
        BWTransaction {
            id: Uuid::new_v4(),
            title: title.into(),
            description: String::new(),
            date: BWDate { year: 2026, month: 10, day: 20 },
            amount: BWMoneyAmount { value: cents },
        },
    )
    .unwrap()
}

fn add_category(budget: BWBudget, title: &str) -> BWBudget {
    let ordinal = budget.categories.len() as i32;
    domain::create_category(
        budget,
        BWCategory {
            id: Uuid::new_v4(),
            ordinal,
            title: title.into(),
            amount_planned: BWMoneyAmount { value: 1000 },
            amount_actual: BWMoneyAmount { value: 0 },
            amount_accumulated: BWMoneyAmount { value: 0 },
            category_type: BWCategoryType::Expenses,
            transactions: vec![],
        },
    )
    .unwrap()
}

fn transaction_titles(budget: &BWBudget) -> Vec<String> {
    let mut titles: Vec<String> = budget
        .categories
        .iter()
        .flat_map(|category| category.transactions.iter().map(|tx| tx.title.clone()))
        .collect();
    titles.sort();
    titles
}

fn has_category(budget: &BWBudget, title: &str) -> bool {
    budget.categories.iter().any(|category| category.title == title)
}

// MARK: Tests

#[test]
fn sign_in_uses_pkce_and_stores_a_refresh_token() {
    let server = FakeDrive::default();
    let device = signed_in(&server, "ana@example.com");
    assert!(device.drive.is_signed_in());
    assert_eq!(device.drive.account().unwrap().email.as_deref(), Some("ana@example.com"));
    let stored = device.credentials.load_credentials().unwrap();
    assert!(stored.contains("rt-ana@example.com"));

    // A tampered state is rejected and leaves no pending sign-in behind.
    let other = device_with_pending(&server);
    assert!(other.drive.complete_sign_in("http://127.0.0.1:4567/?state=wrong&code=x".into()).is_err());
    assert!(other.drive.complete_sign_in("http://127.0.0.1:4567/?state=wrong&code=x".into()).is_err());
    assert!(!other.drive.is_signed_in());
}

fn device_with_pending(server: &FakeDrive) -> Device {
    let device = device(server);
    device.drive.begin_sign_in("http://127.0.0.1:4567".into()).unwrap();
    device
}

#[test]
fn unconfigured_builds_and_signed_out_calls_explain_themselves() {
    let server = FakeDrive::default();
    let device = device(&server);
    let unconfigured = BWGoogleDrive::new(BWGoogleDriveConfig {
        client_id: " ".into(),
        client_secret: None,
        cache_directory: device.directory.to_string_lossy().into_owned(),
        folder_name: "Budget Warden".into(),
    });
    assert!(!unconfigured.is_configured());
    assert!(unconfigured.begin_sign_in("http://127.0.0.1:1".into()).is_err());

    let error = device.drive.list_budgets().unwrap_err();
    assert!(is_cloud_sign_in_required(error.clone()));
    assert_eq!(cloud_error_message(error), "Sign in to Google Drive to sync your budgets.");
}

#[test]
fn created_budgets_live_in_the_app_folder_and_open_from_a_working_copy() {
    let server = FakeDrive::default();
    let device = signed_in(&server, "ana@example.com");

    let created = device.drive.create_budget("October".into(), new_budget_json("October")).unwrap();
    let second = device.drive.create_budget("Nov/ember.budget".into(), new_budget_json("November")).unwrap();
    assert_eq!(created.name, "October.budget");
    assert_eq!(second.name, "Nov-ember.budget");
    assert!(!created.shared_with_me && created.can_edit && created.can_share);

    let file = server.file(&created.id);
    assert_eq!(file.mime_type, BUDGET_MIME_TYPE);
    assert_eq!(file.app_properties["budgetWarden"], "budget");
    let folder = server.file(&file.parents[0]);
    assert_eq!(folder.name, "Budget Warden");
    assert_eq!(server.file(&second.id).parents, file.parents, "the folder is created once");

    let path = created.local_path.clone().unwrap();
    assert!(device.drive.is_cloud_path(path.clone()));
    assert_eq!(device.drive.budget_id_for_path(path.clone()), Some(created.id.clone()));
    assert_eq!(read_budget(&path).title, "October");
    assert!(!device.drive.is_cloud_path(device.directory.join("elsewhere.budget").to_string_lossy().into_owned()));

    let listed = device.drive.list_budgets().unwrap();
    assert_eq!(listed.len(), 2);
    assert_eq!(device.drive.cached_budgets(), listed);
}

#[test]
fn concurrent_edits_on_two_devices_converge() {
    let server = FakeDrive::default();
    let laptop = signed_in(&server, "ana@example.com");
    let phone = signed_in(&server, "ana@example.com");

    let created = laptop.drive.create_budget("Shared".into(), new_budget_json("Shared")).unwrap();
    let laptop_path = created.local_path.unwrap();
    let opened = phone.drive.open_budget(created.id.clone()).unwrap();
    assert!(opened.local_changed && !opened.remote_changed);
    let phone_path = opened.local_path;

    app_edit(&laptop_path, |budget| add_transaction(budget, "Coffee", 450));
    app_edit(&phone_path, |budget| add_category(budget, "Gym"));
    app_edit(&phone_path, |budget| add_transaction(budget, "Bus", 280));

    let laptop_sync = laptop.drive.sync_budget(created.id.clone()).unwrap();
    assert!(laptop_sync.remote_changed && !laptop_sync.local_changed);
    let phone_sync = phone.drive.sync_budget(created.id.clone()).unwrap();
    assert!(phone_sync.remote_changed && phone_sync.local_changed);
    let laptop_sync = laptop.drive.sync_budget(created.id.clone()).unwrap();
    assert!(laptop_sync.local_changed && !laptop_sync.remote_changed);

    for path in [&laptop_path, &phone_path] {
        let budget = read_budget(path);
        assert_eq!(transaction_titles(&budget), vec!["Bus", "Coffee"]);
        assert!(has_category(&budget, "Gym"));
    }
    let remote = decode_budget(&server.file(&created.id).content, String::new()).unwrap();
    assert_eq!(transaction_titles(&remote), vec!["Bus", "Coffee"]);

    // Once converged, syncing neither uploads nor downloads.
    let (downloads, uploads) = server.counts();
    for device in [&laptop, &phone] {
        let result = device.drive.sync_budget(created.id.clone()).unwrap();
        assert!(!result.local_changed && !result.remote_changed);
    }
    assert_eq!(server.counts(), (downloads, uploads));
}

#[test]
fn a_lost_upload_race_heals_on_the_next_sync() {
    let server = FakeDrive::default();
    let first = signed_in(&server, "ana@example.com");
    let second = signed_in(&server, "ana@example.com");
    let created = first.drive.create_budget("Race".into(), new_budget_json("Race")).unwrap();
    let first_path = created.local_path.unwrap();
    let second_path = second.drive.open_budget(created.id.clone()).unwrap().local_path;

    app_edit(&second_path, |budget| add_transaction(budget, "Second", 100));
    second.drive.sync_budget(created.id.clone()).unwrap();

    // Another writer replaces Drive content with a stale copy, as a
    // last-writer-wins race would.
    let stale = std::fs::read_to_string(first.directory.join("google-drive").join(&created.id).join("remote.json")).unwrap();
    {
        let mut state = server.state.lock().unwrap();
        let file = state.files.get_mut(&created.id).unwrap();
        file.content = stale;
        file.version += 1;
    }
    app_edit(&first_path, |budget| add_transaction(budget, "First", 200));
    first.drive.sync_budget(created.id.clone()).unwrap();
    // The second device still holds its edit and pushes it again.
    let result = second.drive.sync_budget(created.id.clone()).unwrap();
    assert!(result.remote_changed && result.local_changed);
    first.drive.sync_budget(created.id.clone()).unwrap();
    assert_eq!(transaction_titles(&read_budget(&first_path)), vec!["First", "Second"]);
}

#[test]
fn shared_budgets_are_discovered_and_editable_by_writers_only() {
    let server = FakeDrive::default();
    let owner = signed_in(&server, "ana@example.com");
    let writer = signed_in(&server, "ben@example.com");
    let reader = signed_in(&server, "cy@example.com");

    let created = owner.drive.create_budget("Family".into(), new_budget_json("Family")).unwrap();
    assert!(writer.drive.list_budgets().unwrap().is_empty());

    let share = owner
        .drive
        .share_budget(created.id.clone(), " ben@example.com ".into(), BWCloudShareRole::Writer, Some("Our budget".into()))
        .unwrap();
    assert_eq!(share.role, BWCloudShareRole::Writer);
    owner
        .drive
        .share_budget(created.id.clone(), "cy@example.com".into(), BWCloudShareRole::Reader, None)
        .unwrap();
    assert!(owner.drive.share_budget(created.id.clone(), "not an email".into(), BWCloudShareRole::Reader, None).is_err());
    assert_eq!(server.state.lock().unwrap().notifications, vec!["ben@example.com", "cy@example.com"]);

    let shares = owner.drive.list_shares(created.id.clone()).unwrap();
    assert_eq!(shares.iter().map(|s| s.role).collect::<Vec<_>>(), vec![
        BWCloudShareRole::Owner,
        BWCloudShareRole::Writer,
        BWCloudShareRole::Reader
    ]);
    assert!(owner.drive.list_budgets().unwrap()[0].is_shared);

    let discovered = writer.drive.list_budgets().unwrap();
    assert_eq!(discovered.len(), 1);
    assert!(discovered[0].shared_with_me && discovered[0].can_edit);
    assert_eq!(discovered[0].owner_email.as_deref(), Some("ana@example.com"));

    let writer_path = writer.drive.open_budget(created.id.clone()).unwrap().local_path;
    app_edit(&writer_path, |budget| add_transaction(budget, "Groceries", 5000));
    assert!(writer.drive.sync_budget(created.id.clone()).unwrap().remote_changed);
    let owner_result = owner.drive.sync_budget(created.id.clone()).unwrap();
    assert!(owner_result.local_changed);
    assert_eq!(transaction_titles(&read_budget(&owner_result.local_path)), vec!["Groceries"]);

    let reader_budget = &reader.drive.list_budgets().unwrap()[0];
    assert!(reader_budget.shared_with_me && !reader_budget.can_edit);
    let reader_path = reader.drive.open_budget(created.id.clone()).unwrap().local_path;
    app_edit(&reader_path, |budget| add_transaction(budget, "Sneaky", 1));
    let reader_result = reader.drive.sync_budget(created.id.clone()).unwrap();
    assert!(!reader_result.remote_changed, "readers never upload");

    // Revoking access hides the budget and removes its unchanged copy.
    let ben = shares.iter().find(|s| s.email.as_deref() == Some("ben@example.com")).unwrap();
    owner.drive.remove_share(created.id.clone(), ben.id.clone()).unwrap();
    assert!(writer.drive.list_budgets().unwrap().is_empty());
    assert!(!Path::new(&writer_path).exists());
    // A reader with local edits that never reached Drive keeps them.
    let cy = shares.iter().find(|s| s.email.as_deref() == Some("cy@example.com")).unwrap();
    owner.drive.remove_share(created.id.clone(), cy.id.clone()).unwrap();
    assert_eq!(reader.drive.list_budgets().unwrap().len(), 1);
    assert!(Path::new(&reader_path).exists());
}

#[test]
fn expired_tokens_refresh_and_revoked_sign_ins_ask_to_sign_in_again() {
    let server = FakeDrive::default();
    let device = signed_in(&server, "ana@example.com");
    device.drive.create_budget("A".into(), new_budget_json("A")).unwrap();

    server.expire_access_tokens();
    assert_eq!(device.drive.list_budgets().unwrap().len(), 1);

    server.expire_access_tokens();
    server.revoke_refresh_tokens();
    let error = device.drive.list_budgets().unwrap_err();
    assert!(is_cloud_sign_in_required(error));
    assert!(!device.drive.is_signed_in());
    // Working copies stay listed offline.
    assert_eq!(device.drive.cached_budgets().len(), 1);
}

#[test]
fn sign_out_revokes_and_forgets_working_copies() {
    let server = FakeDrive::default();
    let device = signed_in(&server, "ana@example.com");
    let created = device.drive.create_budget("A".into(), new_budget_json("A")).unwrap();
    device.drive.sign_out();
    assert!(!device.drive.is_signed_in());
    assert!(device.drive.cached_budgets().is_empty());
    assert!(!Path::new(&created.local_path.unwrap()).exists());
    assert!(server.state.lock().unwrap().requests.iter().any(|r| r.starts_with(&format!("POST {REVOCATION_ENDPOINT}"))));
}

#[test]
fn a_deleted_app_folder_is_recreated() {
    let server = FakeDrive::default();
    let device = signed_in(&server, "ana@example.com");
    let first = device.drive.create_budget("A".into(), new_budget_json("A")).unwrap();
    let folder = server.file(&first.id).parents[0].clone();
    server.state.lock().unwrap().files.remove(&folder);
    let second = device.drive.create_budget("B".into(), new_budget_json("B")).unwrap();
    assert_ne!(server.file(&second.id).parents[0], folder);
}

struct StaticTokens(Arc<Mutex<Vec<bool>>>, String);

impl BWGoogleTokenSource for StaticTokens {
    fn access_token(&self, force_refresh: bool) -> Result<Option<String>, String> {
        self.0.lock().unwrap().push(force_refresh);
        Ok(Some(self.1.clone()))
    }
}

#[test]
fn platform_token_sources_replace_the_oauth_flow() {
    let server = FakeDrive::default();
    let device = device(&server);
    server.state.lock().unwrap().access_tokens.insert("play-token".into(), "dee@example.com".into());
    let calls = Arc::new(Mutex::new(Vec::new()));
    device.drive.use_token_source(Box::new(StaticTokens(calls.clone(), "play-token".into())));
    assert!(device.drive.is_configured());
    assert!(!device.drive.is_signed_in());
    assert_eq!(device.drive.refresh_account().unwrap().email.as_deref(), Some("dee@example.com"));
    assert!(device.drive.is_signed_in());
    device.drive.create_budget("Play".into(), new_budget_json("Play")).unwrap();
    assert!(calls.lock().unwrap().iter().all(|forced| !forced));
}
