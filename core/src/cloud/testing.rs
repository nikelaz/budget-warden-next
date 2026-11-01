/*
 * Budget Warden
 * Copyright (c) 2026 Lazarov & Co EOOD
 * Author: Nikola Lazarov
 *
 * Licensed under the Source-Available Educational License.
 * See the LICENSE file in the project root for full terms.
 */

//! An in-memory Google Drive and OAuth server for tests, available to other
//! crates through the `test-support` feature.

use std::collections::{BTreeMap, BTreeSet};
use std::sync::{Arc, Mutex};

use serde_json::{Value, json};
use uuid::Uuid;

use super::BWGoogleCredentialStore;
use super::drive::{API_ROOT, BUDGET_MIME_TYPE, UPLOAD_ROOT};
use super::http::{BWHttpClient, BWHttpRequest, BWHttpResponse, query_pairs};
use super::oauth::{REVOCATION_ENDPOINT, TOKEN_ENDPOINT};

#[derive(Clone, Debug)]
pub struct FakeFile {
    pub name: String,
    pub mime_type: String,
    pub owner: String,
    pub parents: Vec<String>,
    pub content: String,
    pub version: u64,
    pub app_properties: Value,
    /// (permission id, email, role)
    pub permissions: Vec<(String, String, String)>,
    pub trashed: bool,
}

#[derive(Default)]
pub struct FakeDriveState {
    pub files: BTreeMap<String, FakeFile>,
    pub next_id: u64,
    /// access token -> email
    pub access_tokens: BTreeMap<String, String>,
    /// refresh token -> email
    pub refresh_tokens: BTreeMap<String, String>,
    /// authorization code -> (email, code challenge)
    pub codes: BTreeMap<String, (String, String)>,
    pub downloads: usize,
    pub uploads: usize,
    pub notifications: Vec<String>,
    /// The `emailMessage` of each invitation, in order.
    pub invitation_messages: Vec<String>,
    pub requests: Vec<String>,
    /// (user, file id) pairs the user chose for the app in the picker.
    pub picked: BTreeSet<(String, String)>,
}

/// Serves the Drive and OAuth endpoints the core uses, for any number of
/// users. Pass clones to several `BWGoogleDrive`s to simulate devices.
#[derive(Clone, Default)]
pub struct FakeDrive {
    pub state: Arc<Mutex<FakeDriveState>>,
}

fn response(status: i32, body: Value) -> BWHttpResponse {
    BWHttpResponse {
        status,
        headers: vec![],
        body: body.to_string(),
    }
}

fn error(status: i32, message: &str) -> BWHttpResponse {
    response(
        status,
        json!({ "error": { "code": status, "message": message } }),
    )
}

impl FakeDrive {
    fn new_id(state: &mut FakeDriveState, prefix: &str) -> String {
        state.next_id += 1;
        format!("{prefix}{}", state.next_id)
    }

    /// Lets `email` complete an OAuth flow whose authorization URL was `url`.
    pub fn approve(&self, url: &str, email: &str) -> String {
        let pairs = query_pairs(url);
        let get = |name: &str| pairs.iter().find(|(k, _)| k == name).unwrap().1.clone();
        let code = format!("code-{}", Uuid::new_v4().simple());
        self.state
            .lock()
            .unwrap()
            .codes
            .insert(code.clone(), (email.to_string(), get("code_challenge")));
        format!(
            "{}?state={}&code={}",
            get("redirect_uri"),
            get("state"),
            code
        )
    }

    pub fn expire_access_tokens(&self) {
        self.state.lock().unwrap().access_tokens.clear();
    }

    pub fn revoke_refresh_tokens(&self) {
        self.state.lock().unwrap().refresh_tokens.clear();
    }

    pub fn file(&self, id: &str) -> FakeFile {
        self.state.lock().unwrap().files[id].clone()
    }

    pub fn counts(&self) -> (usize, usize) {
        let state = self.state.lock().unwrap();
        (state.downloads, state.uploads)
    }

    /// Simulates `email` choosing a file for Budget Warden in the Google
    /// Picker, which grants the app `drive.file` access to it.
    pub fn pick(&self, email: &str, file_id: &str) {
        self.state
            .lock()
            .unwrap()
            .picked
            .insert((email.to_string(), file_id.to_string()));
    }

    /// Lets `token` act as `email` without an OAuth flow.
    pub fn grant_access_token(&self, token: &str, email: &str) {
        self.state
            .lock()
            .unwrap()
            .access_tokens
            .insert(token.to_string(), email.to_string());
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

    /// The user's role as seen through the `drive.file` scope: the app only
    /// reaches files the user owns through it or picked for it.
    fn app_role(
        picked: &BTreeSet<(String, String)>,
        id: &str,
        file: &FakeFile,
        user: &str,
    ) -> Option<String> {
        let reachable = file.owner == user || picked.contains(&(user.to_string(), id.to_string()));
        reachable.then(|| Self::role(file, user)).flatten()
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
        state
            .requests
            .push(format!("{} {}", request.method, request.url));
        let path = request.url.split('?').next().unwrap().to_string();
        let query: BTreeMap<String, String> = query_pairs(&request.url).into_iter().collect();
        let body = request.body.clone().unwrap_or_default();

        if path == TOKEN_ENDPOINT {
            let form: BTreeMap<String, String> =
                query_pairs(&format!("?{body}")).into_iter().collect();
            assert_eq!(
                form.get("client_id").map(String::as_str),
                Some("test-client")
            );
            let email = match form["grant_type"].as_str() {
                "authorization_code" => {
                    let Some((email, challenge)) = state.codes.remove(&form["code"]) else {
                        return response(400, json!({ "error": "invalid_grant" }));
                    };
                    assert_eq!(
                        super::oauth::code_challenge(&form["code_verifier"]),
                        challenge
                    );
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
            return response(
                200,
                json!({ "access_token": access, "expires_in": 3599, "refresh_token": refresh }),
            );
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
            return response(
                200,
                json!({ "user": { "displayName": user.split('@').next(), "emailAddress": user } }),
            );
        }

        if path == format!("{API_ROOT}/files") && request.method == "GET" {
            let q = &query["q"];
            let files: Vec<Value> = state
                .files
                .iter()
                .filter(|(id, file)| {
                    !file.trashed && Self::app_role(&state.picked, id, file, &user).is_some()
                })
                .filter(|(_, file)| {
                    if q.contains("google-apps.folder") {
                        file.mime_type == "application/vnd.google-apps.folder"
                            && q.contains(&format!("name = '{}'", file.name))
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
            let content_type = request
                .headers
                .iter()
                .find(|h| h.name == "Content-Type")
                .unwrap()
                .value
                .clone();
            let boundary = content_type.split("boundary=").nth(1).unwrap().to_string();
            let parts: Vec<&str> = body.split(&format!("--{boundary}")).collect();
            let metadata: Value =
                serde_json::from_str(parts[1].split("\r\n\r\n").nth(1).unwrap().trim()).unwrap();
            let content = parts[2]
                .split_once("\r\n\r\n")
                .unwrap()
                .1
                .trim_end_matches("\r\n")
                .to_string();
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
        let Some(role) = Self::app_role(&state.picked, &id, &file, &user) else {
            return error(404, "File not found");
        };

        match (request.method.as_str(), segments.next(), segments.next()) {
            ("GET", None, None) if query.get("alt").map(String::as_str) == Some("media") => {
                state.downloads += 1;
                BWHttpResponse {
                    status: 200,
                    headers: vec![],
                    body: file.content,
                }
            }
            ("GET", None, None) => response(200, Self::metadata(&id, &file, &user)),
            ("PATCH", None, None) => {
                assert!(path.starts_with(UPLOAD_ROOT));
                if role != "owner" && role != "writer" {
                    return error(
                        403,
                        "The user does not have sufficient permissions for this file.",
                    );
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
                state
                    .invitation_messages
                    .push(query.get("emailMessage").cloned().unwrap_or_default());
                let file = state.files.get_mut(&id).unwrap();
                file.permissions
                    .push((permission_id.clone(), email.clone(), role.clone()));
                file.version += 1;
                response(
                    200,
                    json!({ "id": permission_id, "type": "user", "role": role, "emailAddress": email }),
                )
            }
            ("GET", Some("permissions"), None) => {
                let mut permissions = vec![
                    json!({ "id": "owner", "type": "user", "role": "owner", "emailAddress": file.owner }),
                ];
                permissions.extend(file.permissions.iter().map(|(pid, email, role)| {
                    json!({ "id": pid, "type": "user", "role": role, "emailAddress": email })
                }));
                response(200, json!({ "permissions": permissions }))
            }
            ("DELETE", Some("permissions"), Some(permission_id)) => {
                let permission_id = permission_id.to_string();
                let file = state.files.get_mut(&id).unwrap();
                file.permissions.retain(|(pid, _, _)| *pid != permission_id);
                BWHttpResponse {
                    status: 204,
                    headers: vec![],
                    body: String::new(),
                }
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

/// Decoded query parameters of `url`, for tests that play a browser.
pub fn query(url: &str) -> Vec<(String, String)> {
    query_pairs(url)
}

/// Credentials kept in memory.
#[derive(Clone, Default)]
pub struct MemoryCredentials(pub Arc<Mutex<Option<String>>>);

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
