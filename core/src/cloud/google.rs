/*
 * Budget Warden
 * Copyright (c) 2026 Lazarov & Co EOOD
 * Author: Nikola Lazarov
 *
 * Licensed under the Source-Available Educational License.
 * See the LICENSE file in the project root for full terms.
 */

//! [`BWGoogleDrive`]: sign-in, listing, sync, and sharing of cloud budgets.

use std::path::Path;
use std::sync::{Arc, Mutex, MutexGuard};

use boltffi::*;

use super::drive::{self, DriveFile, DrivePermission};
use super::http::{BWHttpClient, BWHttpRequest, BWHttpResponse};
use super::oauth::{self, GOOGLE_DRIVE_SCOPE, PendingSignIn, StoredCredentials};
use super::sync::{self, Cache, CacheState, CachedFile};
use super::{AUTH_REQUIRED_PREFIX, BWGoogleSignInRequest, auth_required};
use crate::codec::{decode_budget, encode_budget};

/// Number of times sync re-reads the working copy when the app saved it
/// while sync was merging.
const MAX_LOCAL_WRITE_ATTEMPTS: usize = 3;

/// Secure storage for the signed-in account (Keychain, Credential Locker,
/// a private file). Values are opaque JSON written by the core.
#[export]
pub trait BWGoogleCredentialStore: Send + Sync {
    fn load_credentials(&self) -> Option<String>;
    fn save_credentials(&self, credentials: String) -> Result<(), String>;
    fn delete_credentials(&self);
}

/// Supplies access tokens from a platform account service instead of the
/// core's OAuth flow. Android uses this with Google Play services.
#[export]
pub trait BWGoogleTokenSource: Send + Sync {
    /// A current access token, or `None` when the user must sign in
    /// interactively. `force_refresh` asks for a new token because Drive
    /// rejected the previous one.
    fn access_token(&self, force_refresh: bool) -> Result<Option<String>, String>;
}

#[data]
#[derive(Clone, Debug, PartialEq)]
pub struct BWGoogleDriveConfig {
    /// OAuth client ID for this platform. Empty when the build has none,
    /// unless the app uses a [`BWGoogleTokenSource`].
    pub client_id: String,
    /// Client secret of a "Desktop app" OAuth client. Google requires it for
    /// desktop token exchanges even though it cannot be kept secret.
    pub client_secret: Option<String>,
    /// App-private directory for working copies of cloud budgets.
    pub cache_directory: String,
    /// Drive folder for new budgets, created in My Drive when missing.
    pub folder_name: String,
    /// Address of the hosted shared-budget picker page (`picker/` in the
    /// repository), or `None` when this build cannot add shared budgets.
    pub picker_url: Option<String>,
}

#[data]
#[derive(Clone, Debug, PartialEq)]
pub struct BWGoogleAccount {
    pub email: Option<String>,
    pub display_name: Option<String>,
}

/// A budget file in Google Drive.
#[data]
#[derive(Clone, Debug, PartialEq)]
pub struct BWCloudBudget {
    /// Drive file ID.
    pub id: String,
    /// Drive file name, for example `October.budget`.
    pub name: String,
    /// Name without the `.budget` extension, for display.
    pub title: String,
    pub owner_name: Option<String>,
    pub owner_email: Option<String>,
    /// Someone else owns this budget and shared it with the user.
    pub shared_with_me: bool,
    /// Anyone besides the owner has access.
    pub is_shared: bool,
    pub can_edit: bool,
    pub can_share: bool,
    /// RFC 3339 time of the last change in Drive.
    pub modified_time: Option<String>,
    pub web_link: Option<String>,
    /// Working copy on this device, once the budget has been opened.
    pub local_path: Option<String>,
}

#[data]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum BWCloudShareRole {
    Owner = 1,
    Writer = 2,
    Commenter = 3,
    Reader = 4,
}

/// A person or group with access to a cloud budget.
#[data]
#[derive(Clone, Debug, PartialEq)]
pub struct BWCloudShare {
    pub id: String,
    pub role: BWCloudShareRole,
    pub email: Option<String>,
    pub display_name: Option<String>,
    /// `user`, `group`, `domain`, or `anyone`.
    pub kind: String,
}

#[data]
#[derive(Clone, Debug, PartialEq)]
pub struct BWCloudSyncResult {
    pub budget: BWCloudBudget,
    /// Working copy to open; equals `budget.local_path`.
    pub local_path: String,
    /// Sync rewrote the working copy, so an open budget must be reloaded.
    pub local_changed: bool,
    /// Sync uploaded changes to Drive.
    pub remote_changed: bool,
}

struct Connection {
    http: Arc<dyn BWHttpClient>,
    credentials: Arc<dyn BWGoogleCredentialStore>,
}

/// Google Drive storage for budgets. Apps keep one for their lifetime and
/// call it from background threads; every network call blocks.
pub struct BWGoogleDrive {
    config: BWGoogleDriveConfig,
    cache: Cache,
    connection: Mutex<Option<Connection>>,
    token_source: Mutex<Option<Arc<dyn BWGoogleTokenSource>>>,
    pending_sign_in: Mutex<Option<PendingSignIn>>,
    /// Serializes operations that read and write the cache state.
    state_lock: Mutex<()>,
    /// Serializes token refreshes so concurrent calls share one refresh.
    token_lock: Mutex<()>,
}

/// Removes the internal sign-in marker from an error before showing it.
#[export]
pub fn cloud_error_message(message: String) -> String {
    message
        .strip_prefix(AUTH_REQUIRED_PREFIX)
        .map(str::to_string)
        .unwrap_or(message)
}

/// The redirect URI of an iOS-type OAuth client: its reversed client ID.
#[export]
pub fn google_apple_redirect_uri(client_id: String) -> String {
    format!(
        "{}:/oauth2redirect",
        google_apple_callback_scheme(client_id)
    )
}

/// URL scheme `ASWebAuthenticationSession` should wait for.
#[export]
pub fn google_apple_callback_scheme(client_id: String) -> String {
    let prefix = client_id
        .trim()
        .strip_suffix(".apps.googleusercontent.com")
        .unwrap_or(client_id.trim());
    format!("com.googleusercontent.apps.{prefix}")
}

#[export]
impl BWGoogleDrive {
    pub fn new(config: BWGoogleDriveConfig) -> Self {
        let cache = Cache::new(&config.cache_directory);
        Self {
            config,
            cache,
            connection: Mutex::new(None),
            token_source: Mutex::new(None),
            pending_sign_in: Mutex::new(None),
            state_lock: Mutex::new(()),
            token_lock: Mutex::new(()),
        }
    }

    /// Supplies networking and credential storage. Call once before use.
    pub fn connect(
        &self,
        http: Box<dyn BWHttpClient>,
        credentials: Box<dyn BWGoogleCredentialStore>,
    ) {
        *lock(&self.connection) = Some(Connection {
            http: Arc::from(http),
            credentials: Arc::from(credentials),
        });
    }

    /// Uses platform-issued access tokens instead of the core OAuth flow.
    pub fn use_token_source(&self, source: Box<dyn BWGoogleTokenSource>) {
        *lock(&self.token_source) = Some(Arc::from(source));
    }

    /// Whether this build can sign in to Google Drive at all.
    pub fn is_configured(&self) -> bool {
        lock(&self.token_source).is_some() || !self.config.client_id.trim().is_empty()
    }

    pub fn is_signed_in(&self) -> bool {
        if lock(&self.token_source).is_some() {
            return self.account().is_some();
        }
        self.credentials().is_some_and(|credentials| {
            credentials.refresh_token.is_some() || credentials.access_token.is_some()
        })
    }

    pub fn account(&self) -> Option<BWGoogleAccount> {
        let credentials = self.credentials()?;
        (credentials.email.is_some()
            || credentials.refresh_token.is_some()
            || credentials.access_token.is_some())
        .then_some(BWGoogleAccount {
            email: credentials.email,
            display_name: credentials.display_name,
        })
    }

    /// Starts the OAuth flow. Open `authorization_url` in a browser and pass
    /// the URL it redirects to to [`Self::complete_sign_in`].
    pub fn begin_sign_in(&self, redirect_uri: String) -> Result<BWGoogleSignInRequest, String> {
        if self.config.client_id.trim().is_empty() {
            return Err(
                "Google Drive is not configured in this build of Budget Warden.".to_string(),
            );
        }
        let state = uuid::Uuid::new_v4().simple().to_string();
        let code_verifier = oauth::new_code_verifier();
        let authorization_url = oauth::authorization_url(
            self.config.client_id.trim(),
            &redirect_uri,
            GOOGLE_DRIVE_SCOPE,
            &state,
            &code_verifier,
            None,
        );
        *lock(&self.pending_sign_in) = Some(PendingSignIn {
            state: state.clone(),
            code_verifier,
            redirect_uri: redirect_uri.clone(),
        });
        Ok(BWGoogleSignInRequest {
            authorization_url,
            redirect_uri,
            state,
        })
    }

    /// Finishes sign-in with the redirect URL the browser returned to.
    pub fn complete_sign_in(&self, callback_url: String) -> Result<BWGoogleAccount, String> {
        let pending = lock(&self.pending_sign_in)
            .take()
            .ok_or_else(|| "Google sign-in has not started.".to_string())?;
        let code = oauth::authorization_code(&callback_url, &pending.state)?;
        let connection = self.connection()?;
        let grant = oauth::request_token(
            connection.http.as_ref(),
            self.config.client_id.trim(),
            self.config.client_secret.as_deref(),
            &[
                ("grant_type", "authorization_code"),
                ("code", &code),
                ("code_verifier", &pending.code_verifier),
                ("redirect_uri", &pending.redirect_uri),
            ],
        )
        .map_err(cloud_error_message)?;
        let previous = self.credentials().unwrap_or_default();
        let credentials = StoredCredentials {
            refresh_token: grant.refresh_token.or(previous.refresh_token),
            access_token: Some(grant.access_token),
            expires_at_ms: grant.expires_at_ms,
            email: None,
            display_name: None,
        };
        connection
            .credentials
            .save_credentials(credentials.encode())?;
        // A different account may have signed in: forget the old mirror.
        self.cache.clear();
        self.refresh_account()
    }

    /// Reads the signed-in account's name and email from Drive.
    pub fn refresh_account(&self) -> Result<BWGoogleAccount, String> {
        let response = self.send(drive::about_request())?;
        if !response.is_success() {
            return Err(drive::error_message(&response));
        }
        let user = drive::parse_about(&response)?;
        let connection = self.connection()?;
        let mut credentials = self.credentials().unwrap_or_default();
        if credentials.email.is_some() && credentials.email != user.email_address {
            self.cache.clear();
        }
        credentials.email = user.email_address.clone();
        credentials.display_name = user.display_name.clone();
        connection
            .credentials
            .save_credentials(credentials.encode())?;
        Ok(BWGoogleAccount {
            email: user.email_address,
            display_name: user.display_name,
        })
    }

    /// Signs out, revokes the refresh token, and removes working copies.
    pub fn sign_out(&self) {
        let _state = lock(&self.state_lock);
        if let Ok(connection) = self.connection() {
            if let Some(token) = self
                .credentials()
                .and_then(|credentials| credentials.refresh_token.or(credentials.access_token))
            {
                oauth::revoke(connection.http.as_ref(), &token);
            }
            connection.credentials.delete_credentials();
        }
        self.cache.clear();
    }

    /// Budgets known from the last listing, without network access.
    pub fn cached_budgets(&self) -> Vec<BWCloudBudget> {
        let _state = lock(&self.state_lock);
        let state = self.cache.load_state();
        let mut budgets: Vec<_> = state
            .files
            .iter()
            .map(|(id, cached)| self.summary(id, cached))
            .collect();
        sort_budgets(&mut budgets);
        budgets
    }

    /// Lists the user's budgets in Drive, including ones shared with them.
    pub fn list_budgets(&self) -> Result<Vec<BWCloudBudget>, String> {
        let mut files = Vec::new();
        let mut page_token: Option<String> = None;
        let query = drive::budgets_query();
        loop {
            let response = self.send(drive::list_files_request(&query, page_token.as_deref()))?;
            if !response.is_success() {
                return Err(drive::error_message(&response));
            }
            let (page, next) = drive::parse_file_list(&response)?;
            files.extend(page.into_iter().filter(|file| file.trashed != Some(true)));
            match next {
                Some(token) if !token.is_empty() => page_token = Some(token),
                _ => break,
            }
        }

        let _state = lock(&self.state_lock);
        let mut state = self.cache.load_state();
        let listed: std::collections::BTreeSet<String> =
            files.iter().map(|file| file.id.clone()).collect();
        // Forget budgets that disappeared from Drive, unless their working
        // copy holds edits that never reached Drive.
        let vanished: Vec<String> = state
            .files
            .keys()
            .filter(|id| !listed.contains(*id))
            .cloned()
            .collect();
        for id in vanished {
            if !self.has_unsynced_changes(&id, &state.files[&id]) {
                state.files.remove(&id);
                self.cache.remove(&id);
            }
        }
        for file in files {
            let local_name = state
                .files
                .get(&file.id)
                .map(|cached| cached.local_name.clone())
                .unwrap_or_else(|| sync::local_file_name(&file.name));
            let snapshot_version = state
                .files
                .get(&file.id)
                .and_then(|cached| cached.snapshot_version.clone());
            state.files.insert(
                file.id.clone(),
                CachedFile {
                    file,
                    local_name,
                    snapshot_version,
                },
            );
        }
        self.cache.save_state(&state)?;
        let mut budgets: Vec<_> = state
            .files
            .iter()
            .map(|(id, cached)| self.summary(id, cached))
            .collect();
        sort_budgets(&mut budgets);
        Ok(budgets)
    }

    /// Downloads a budget if needed and returns its working copy.
    pub fn open_budget(&self, file_id: String) -> Result<BWCloudSyncResult, String> {
        self.sync_budget(file_id)
    }

    /// Reconciles the working copy with Drive: downloads remote changes,
    /// merges them, and uploads local changes.
    pub fn sync_budget(&self, file_id: String) -> Result<BWCloudSyncResult, String> {
        let metadata = self.metadata(&file_id)?;
        let _state = lock(&self.state_lock);
        let mut state = self.cache.load_state();
        let mut cached = state
            .files
            .get(&file_id)
            .cloned()
            .unwrap_or_else(|| CachedFile {
                local_name: sync::local_file_name(&metadata.name),
                file: metadata.clone(),
                snapshot_version: None,
            });
        cached.file = metadata.clone();

        let remote_json = self.remote_content(&file_id, &mut cached)?;
        let working_copy = self.cache.working_copy(&file_id, &cached.local_name);
        let location = working_copy.to_string_lossy().into_owned();

        let mut local_changed = false;
        let mut remote_changed = false;
        if !working_copy.exists() {
            let remote = decode_budget(&remote_json, location.clone())
                .map_err(|error| format!("{} is not a readable budget: {error}", metadata.name))?;
            sync::write_atomically(&working_copy, &encode_budget(&remote)?)?;
            local_changed = true;
        } else {
            for attempt in 0.. {
                let local_json = read(&working_copy)?;
                let local = decode_budget(&local_json, location.clone())?;
                let remote = decode_budget(&remote_json, location.clone()).map_err(|error| {
                    format!("{} is not a readable budget: {error}", metadata.name)
                })?;
                let local_revision = local.revision_id;
                let reconciliation = sync::reconcile(local, remote)?;
                if reconciliation.local_changed {
                    // The app may have saved while sync merged: merge again
                    // rather than overwrite that save.
                    let current = decode_budget(&read(&working_copy)?, location.clone())?;
                    if current.revision_id != local_revision {
                        if attempt + 1 >= MAX_LOCAL_WRITE_ATTEMPTS {
                            return Err(
                                "The budget kept changing while it was syncing. Please try again."
                                    .to_string(),
                            );
                        }
                        continue;
                    }
                    sync::write_atomically(&working_copy, &encode_budget(&reconciliation.merged)?)?;
                    local_changed = true;
                }
                if reconciliation.remote_changed && cached.file.capabilities.can_edit {
                    let json = encode_budget(&reconciliation.merged)?;
                    let response = self.send(drive::update_content_request(&file_id, &json))?;
                    if !response.is_success() {
                        return Err(drive::error_message(&response));
                    }
                    let updated = drive::parse_file(&response)?;
                    sync::write_atomically(&self.cache.snapshot(&file_id), &json)?;
                    cached.snapshot_version = updated.version.clone();
                    cached.file = updated;
                    remote_changed = true;
                }
                break;
            }
        }

        state.files.insert(file_id.clone(), cached.clone());
        self.cache.save_state(&state)?;
        Ok(BWCloudSyncResult {
            budget: self.summary(&file_id, &cached),
            local_path: location,
            local_changed,
            remote_changed,
        })
    }

    /// Uploads a new budget to the app's Drive folder and returns it with a
    /// working copy ready to open. `json` is an encoded budget.
    pub fn create_budget(&self, file_name: String, json: String) -> Result<BWCloudBudget, String> {
        let budget = decode_budget(&json, String::new())?;
        let json = encode_budget(&budget)?;
        let name = sync::local_file_name(&file_name);
        let file = match self.upload_new(&name, &json, false) {
            Err(error) if error == FOLDER_MISSING => self.upload_new(&name, &json, true)?,
            other => other?,
        };
        let _state = lock(&self.state_lock);
        let mut state = self.cache.load_state();
        let cached = CachedFile {
            local_name: sync::local_file_name(&file.name),
            snapshot_version: file.version.clone(),
            file: file.clone(),
        };
        sync::write_atomically(&self.cache.snapshot(&file.id), &json)?;
        sync::write_atomically(
            &self.cache.working_copy(&file.id, &cached.local_name),
            &json,
        )?;
        state.files.insert(file.id.clone(), cached.clone());
        self.cache.save_state(&state)?;
        Ok(self.summary(&file.id, &cached))
    }

    /// The Drive file ID whose working copy is at `path`.
    pub fn budget_id_for_path(&self, path: String) -> Option<String> {
        let _state = lock(&self.state_lock);
        let state = self.cache.load_state();
        self.cache.file_id_for_path(&state, Path::new(&path))
    }

    /// Whether `path` is inside this provider's cache directory.
    pub fn is_cloud_path(&self, path: String) -> bool {
        let root = std::fs::canonicalize(self.cache.root())
            .unwrap_or_else(|_| self.cache.root().to_path_buf());
        let path = std::fs::canonicalize(&path).unwrap_or_else(|_| Path::new(&path).to_path_buf());
        path.starts_with(root)
    }

    /// Removes the working copy of a budget from this device. Drive keeps it.
    pub fn forget_budget(&self, file_id: String) {
        let _state = lock(&self.state_lock);
        let mut state = self.cache.load_state();
        if let Some(cached) = state.files.get_mut(&file_id) {
            cached.snapshot_version = None;
        }
        self.cache.remove(&file_id);
        let _ = self.cache.save_state(&state);
    }

    /// Gives `email` access to a budget and emails them a link. Their
    /// Budget Warden lists it under budgets shared with them.
    pub fn share_budget(
        &self,
        file_id: String,
        email: String,
        role: BWCloudShareRole,
        message: Option<String>,
    ) -> Result<BWCloudShare, String> {
        let email = email.trim().to_string();
        if !is_plausible_email(&email) {
            return Err("Enter the email address of the person to share with.".to_string());
        }
        let role = match role {
            BWCloudShareRole::Writer => "writer",
            BWCloudShareRole::Commenter => "commenter",
            BWCloudShareRole::Reader => "reader",
            BWCloudShareRole::Owner => {
                return Err("Ownership cannot be transferred from Budget Warden.".to_string());
            }
        };
        // Budget Warden only sees files the recipient picks for it, so the
        // invitation links to the picker with this budget preselected.
        let message = match (self.picker_link(&[file_id.as_str()], None), message) {
            (Some(link), Some(note)) if !note.trim().is_empty() => Some(format!(
                "{}\n\nOpen it in Budget Warden: {link}",
                note.trim()
            )),
            (Some(link), _) => Some(format!("Open it in Budget Warden: {link}")),
            (None, note) => note,
        };
        let response = self.send(drive::create_permission_request(
            &file_id,
            &email,
            role,
            message.as_deref(),
        ))?;
        if !response.is_success() {
            return Err(drive::error_message(&response));
        }
        self.mark_shared(&file_id);
        Ok(share(drive::parse_permission(&response)?))
    }

    /// Whether this build can add budgets shared by others.
    pub fn is_picker_configured(&self) -> bool {
        self.picker_base().is_some()
    }

    /// The picker page to open so the user can choose budgets shared with
    /// them (or uploaded outside Budget Warden). The page sends the browser
    /// to `return_uri` with the chosen file IDs; pass that URL to
    /// [`Self::add_picked_budgets`]. Without a `return_uri` the page asks the
    /// user to return to the app, which should then call
    /// [`Self::list_budgets`].
    pub fn shared_budget_picker_url(&self, return_uri: Option<String>) -> Result<String, String> {
        self.picker_link(&[], return_uri.as_deref()).ok_or_else(|| {
            "Adding shared budgets is not available in this build of Budget Warden.".to_string()
        })
    }

    /// Adds the budgets chosen in the picker, given the URL it returned to.
    /// A cancelled picker adds nothing.
    pub fn add_picked_budgets(&self, callback_url: String) -> Result<Vec<BWCloudBudget>, String> {
        let pairs = super::http::query_pairs(&callback_url);
        let value = |name: &str| {
            pairs
                .iter()
                .find(|(key, _)| key == name)
                .map(|(_, value)| value.clone())
        };
        if let Some(error) = value("error") {
            return Err(format!("Could not choose budgets in Google Drive: {error}"));
        }
        let ids: Vec<String> = value("ids")
            .unwrap_or_default()
            .split(',')
            .map(str::trim)
            .filter(|id| !id.is_empty())
            .map(str::to_string)
            .collect();
        self.add_budgets(ids)
    }

    /// Adds budgets the user granted Budget Warden access to by ID.
    pub fn add_budgets(&self, file_ids: Vec<String>) -> Result<Vec<BWCloudBudget>, String> {
        let mut files = Vec::new();
        for id in file_ids {
            let file = self.metadata(&id)?;
            let is_budget = file.mime_type.as_deref() == Some(drive::BUDGET_MIME_TYPE)
                || file.name.to_lowercase().ends_with(".budget");
            if !is_budget {
                return Err(format!("{} is not a Budget Warden budget.", file.name));
            }
            files.push(file);
        }
        let _state = lock(&self.state_lock);
        let mut state = self.cache.load_state();
        let mut added = Vec::new();
        for file in files {
            let previous = state.files.get(&file.id).cloned();
            let cached = CachedFile {
                local_name: previous
                    .as_ref()
                    .map(|cached| cached.local_name.clone())
                    .unwrap_or_else(|| sync::local_file_name(&file.name)),
                snapshot_version: previous.and_then(|cached| cached.snapshot_version),
                file,
            };
            added.push(self.summary(&cached.file.id, &cached));
            state.files.insert(cached.file.id.clone(), cached);
        }
        self.cache.save_state(&state)?;
        Ok(added)
    }

    /// People and groups with access to a budget, the owner first.
    pub fn list_shares(&self, file_id: String) -> Result<Vec<BWCloudShare>, String> {
        let response = self.send(drive::list_permissions_request(&file_id))?;
        if !response.is_success() {
            return Err(drive::error_message(&response));
        }
        let mut shares: Vec<_> = drive::parse_permissions(&response)?
            .into_iter()
            .map(share)
            .collect();
        shares.sort_by_key(|share| (share.role as i32, share.email.clone().unwrap_or_default()));
        Ok(shares)
    }

    /// Revokes a share returned by [`Self::list_shares`].
    pub fn remove_share(&self, file_id: String, share_id: String) -> Result<(), String> {
        let response = self.send(drive::delete_permission_request(&file_id, &share_id))?;
        if !response.is_success() && response.status != 404 {
            return Err(drive::error_message(&response));
        }
        Ok(())
    }

    /// Root directory of working copies, so apps can tell cloud budgets
    /// apart from local ones in their recent lists.
    pub fn working_directory(&self) -> String {
        self.cache.root().to_string_lossy().into_owned()
    }
}

const FOLDER_MISSING: &str = "folder-missing";

impl BWGoogleDrive {
    fn picker_base(&self) -> Option<&str> {
        self.config
            .picker_url
            .as_deref()
            .map(str::trim)
            .filter(|url| !url.is_empty())
    }

    /// The picker page, optionally preselecting `file_ids` and returning to
    /// `return_uri`.
    fn picker_link(&self, file_ids: &[&str], return_uri: Option<&str>) -> Option<String> {
        let base = self.picker_base()?;
        let ids = file_ids.join(",");
        let email = self.account().and_then(|account| account.email);
        let mut pairs: Vec<(&str, &str)> = Vec::new();
        if !ids.is_empty() {
            pairs.push(("file", &ids));
        }
        if let Some(return_uri) = return_uri {
            pairs.push(("return_to", return_uri));
        }
        if let Some(email) = email.as_deref().filter(|_| return_uri.is_some()) {
            pairs.push(("login_hint", email));
        }
        if pairs.is_empty() {
            return Some(base.to_string());
        }
        let separator = if base.contains('?') { '&' } else { '?' };
        Some(format!(
            "{base}{separator}{}",
            super::http::encode_pairs(&pairs)
        ))
    }

    fn connection(&self) -> Result<Connection, String> {
        lock(&self.connection)
            .as_ref()
            .map(|connection| Connection {
                http: connection.http.clone(),
                credentials: connection.credentials.clone(),
            })
            .ok_or_else(|| "Google Drive is not ready yet.".to_string())
    }

    fn credentials(&self) -> Option<StoredCredentials> {
        let connection = self.connection().ok()?;
        connection
            .credentials
            .load_credentials()
            .and_then(|json| StoredCredentials::decode(&json))
    }

    fn access_token(&self, force_refresh: bool) -> Result<String, String> {
        let source = lock(&self.token_source).clone();
        if let Some(source) = source {
            return source
                .access_token(force_refresh)?
                .ok_or_else(|| auth_required("Sign in to Google Drive to sync your budgets."));
        }
        let _refresh = lock(&self.token_lock);
        let connection = self.connection()?;
        let mut credentials = self
            .credentials()
            .ok_or_else(|| auth_required("Sign in to Google Drive to sync your budgets."))?;
        if !force_refresh && let Some(token) = credentials.valid_access_token(oauth::now_ms()) {
            return Ok(token.to_string());
        }
        let refresh_token = credentials
            .refresh_token
            .clone()
            .ok_or_else(|| auth_required("Sign in to Google Drive to sync your budgets."))?;
        let grant = match oauth::request_token(
            connection.http.as_ref(),
            self.config.client_id.trim(),
            self.config.client_secret.as_deref(),
            &[
                ("grant_type", "refresh_token"),
                ("refresh_token", &refresh_token),
            ],
        ) {
            Ok(grant) => grant,
            Err(error) => {
                if error.starts_with(AUTH_REQUIRED_PREFIX) {
                    connection.credentials.delete_credentials();
                }
                return Err(error);
            }
        };
        credentials.access_token = Some(grant.access_token.clone());
        credentials.expires_at_ms = grant.expires_at_ms;
        if grant.refresh_token.is_some() {
            credentials.refresh_token = grant.refresh_token;
        }
        connection
            .credentials
            .save_credentials(credentials.encode())?;
        Ok(grant.access_token)
    }

    /// Sends an authorized Drive request, refreshing the token once if Drive
    /// rejects it.
    fn send(&self, request: BWHttpRequest) -> Result<BWHttpResponse, String> {
        let http = self.connection()?.http;
        let token = self.access_token(false)?;
        let response = http.execute(authorized(request.clone(), &token))?;
        if response.status != 401 {
            return Ok(response);
        }
        let token = self.access_token(true)?;
        let response = http.execute(authorized(request, &token))?;
        if response.status == 401 {
            return Err(auth_required(
                "Google Drive rejected your sign-in. Sign in again.",
            ));
        }
        Ok(response)
    }

    fn metadata(&self, file_id: &str) -> Result<DriveFile, String> {
        let response = self.send(drive::metadata_request(file_id))?;
        if !response.is_success() {
            return Err(drive::error_message(&response));
        }
        drive::parse_file(&response)
    }

    /// The newest remote content, downloaded only when Drive's version moved
    /// past the local snapshot.
    fn remote_content(&self, file_id: &str, cached: &mut CachedFile) -> Result<String, String> {
        let snapshot = self.cache.snapshot(file_id);
        if cached.snapshot_version.is_some()
            && cached.snapshot_version == cached.file.version
            && let Ok(json) = std::fs::read_to_string(&snapshot)
        {
            return Ok(json);
        }
        let response = self.send(drive::download_request(file_id))?;
        if !response.is_success() {
            return Err(drive::error_message(&response));
        }
        sync::write_atomically(&snapshot, &response.body)?;
        cached.snapshot_version = cached.file.version.clone();
        Ok(response.body)
    }

    fn folder_id(&self, refresh: bool) -> Result<String, String> {
        if !refresh {
            let _state = lock(&self.state_lock);
            if let Some(id) = self.cache.load_state().folder_id {
                return Ok(id);
            }
        }
        let query = drive::folder_query(&self.config.folder_name);
        let response = self.send(drive::list_files_request(&query, None))?;
        if !response.is_success() {
            return Err(drive::error_message(&response));
        }
        let id = match drive::parse_file_list(&response)?.0.into_iter().next() {
            Some(folder) => folder.id,
            None => {
                let response = self.send(drive::create_folder_request(&self.config.folder_name))?;
                if !response.is_success() {
                    return Err(drive::error_message(&response));
                }
                drive::parse_file(&response)?.id
            }
        };
        let _state = lock(&self.state_lock);
        let mut state: CacheState = self.cache.load_state();
        state.folder_id = Some(id.clone());
        self.cache.save_state(&state)?;
        Ok(id)
    }

    fn upload_new(
        &self,
        name: &str,
        json: &str,
        refresh_folder: bool,
    ) -> Result<DriveFile, String> {
        let folder = self.folder_id(refresh_folder)?;
        let response = self.send(drive::create_file_request(name, &folder, json))?;
        if response.status == 404 && !refresh_folder {
            return Err(FOLDER_MISSING.to_string());
        }
        if !response.is_success() {
            return Err(drive::error_message(&response));
        }
        drive::parse_file(&response)
    }

    fn has_unsynced_changes(&self, file_id: &str, cached: &CachedFile) -> bool {
        let working_copy = self.cache.working_copy(file_id, &cached.local_name);
        let Ok(local) = std::fs::read_to_string(&working_copy) else {
            return false;
        };
        let Ok(remote) = std::fs::read_to_string(self.cache.snapshot(file_id)) else {
            return true;
        };
        let location = working_copy.to_string_lossy().into_owned();
        match (
            decode_budget(&local, location.clone()),
            decode_budget(&remote, location),
        ) {
            (Ok(local), Ok(remote)) => sync::content(&local) != sync::content(&remote),
            _ => true,
        }
    }

    fn mark_shared(&self, file_id: &str) {
        let _state = lock(&self.state_lock);
        let mut state = self.cache.load_state();
        if let Some(cached) = state.files.get_mut(file_id) {
            cached.file.shared = Some(true);
            let _ = self.cache.save_state(&state);
        }
    }

    fn summary(&self, file_id: &str, cached: &CachedFile) -> BWCloudBudget {
        let file = &cached.file;
        let owner = file.owners.first().cloned().unwrap_or_default();
        let shared_with_me = file.owned_by_me == Some(false);
        let sharer = file.sharing_user.clone().filter(|_| shared_with_me);
        let working_copy = self.cache.working_copy(file_id, &cached.local_name);
        BWCloudBudget {
            id: file_id.to_string(),
            name: file.name.clone(),
            title: file
                .name
                .strip_suffix(".budget")
                .unwrap_or(&file.name)
                .to_string(),
            owner_name: owner
                .display_name
                .or_else(|| sharer.as_ref().and_then(|user| user.display_name.clone())),
            owner_email: owner
                .email_address
                .or_else(|| sharer.and_then(|user| user.email_address)),
            shared_with_me,
            is_shared: file.shared.unwrap_or(false) || shared_with_me,
            can_edit: file.capabilities.can_edit,
            can_share: file.capabilities.can_share,
            modified_time: file.modified_time.clone(),
            web_link: file.web_view_link.clone(),
            local_path: working_copy
                .exists()
                .then(|| working_copy.to_string_lossy().into_owned()),
        }
    }
}

fn authorized(request: BWHttpRequest, token: &str) -> BWHttpRequest {
    request.header("Authorization", format!("Bearer {token}"))
}

fn read(path: &Path) -> Result<String, String> {
    std::fs::read_to_string(path)
        .map_err(|error| format!("Could not read {}: {error}", path.display()))
}

fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

fn sort_budgets(budgets: &mut [BWCloudBudget]) {
    budgets.sort_by(|left, right| {
        right
            .modified_time
            .cmp(&left.modified_time)
            .then_with(|| left.title.to_lowercase().cmp(&right.title.to_lowercase()))
    });
}

fn share(permission: DrivePermission) -> BWCloudShare {
    BWCloudShare {
        role: match permission.role.as_str() {
            "owner" | "organizer" | "fileOrganizer" => BWCloudShareRole::Owner,
            "writer" => BWCloudShareRole::Writer,
            "commenter" => BWCloudShareRole::Commenter,
            _ => BWCloudShareRole::Reader,
        },
        id: permission.id,
        email: permission.email_address,
        display_name: permission.display_name,
        kind: permission.kind,
    }
}

fn is_plausible_email(email: &str) -> bool {
    let Some((local, domain)) = email.split_once('@') else {
        return false;
    };
    !local.is_empty()
        && domain.contains('.')
        && !domain.starts_with('.')
        && !domain.ends_with('.')
        && !email.chars().any(char::is_whitespace)
}
