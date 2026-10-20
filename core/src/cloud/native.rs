/*
 * Budget Warden
 * Copyright (c) 2026 Lazarov & Co EOOD
 * Author: Nikola Lazarov
 *
 * Licensed under the Source-Available Educational License.
 * See the LICENSE file in the project root for full terms.
 */

//! Cloud plumbing for Rust desktop hosts (Linux and the CLI): a blocking
//! HTTPS client, a private-file credential store, and build configuration.

use std::time::Duration;

use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};

use super::http::{BWHttpClient, BWHttpHeader, BWHttpRequest, BWHttpResponse};
use super::{BWGoogleCredentialStore, BWGoogleDriveConfig};

/// A blocking [`BWHttpClient`] built on `ureq` with rustls. It honors the
/// standard `HTTPS_PROXY` environment variables.
pub struct NativeHttpClient {
    agent: ureq::Agent,
}

impl Default for NativeHttpClient {
    fn default() -> Self {
        Self::new()
    }
}

impl NativeHttpClient {
    pub fn new() -> Self {
        let agent = ureq::Agent::config_builder()
            .http_status_as_error(false)
            .timeout_global(Some(Duration::from_secs(60)))
            .build()
            .new_agent();
        Self { agent }
    }
}

impl BWHttpClient for NativeHttpClient {
    fn execute(&self, request: BWHttpRequest) -> Result<BWHttpResponse, String> {
        let mut builder = ureq::http::Request::builder()
            .method(request.method.as_str())
            .uri(request.url.as_str());
        for header in &request.headers {
            builder = builder.header(header.name.as_str(), header.value.as_str());
        }
        let body = request.body.unwrap_or_default();
        let http_request = builder
            .body(body)
            .map_err(|error| format!("Invalid request: {error}"))?;
        let mut response = self
            .agent
            .run(http_request)
            .map_err(|error| format!("Could not reach the server: {error}"))?;
        let status = i32::from(response.status().as_u16());
        let headers = response
            .headers()
            .iter()
            .map(|(name, value)| BWHttpHeader {
                name: name.to_string(),
                value: value.to_str().unwrap_or_default().to_string(),
            })
            .collect();
        let bytes = response
            .body_mut()
            .with_config()
            .limit(64 * 1024 * 1024)
            .read_to_vec()
            .map_err(|error| format!("Could not read the server response: {error}"))?;
        Ok(BWHttpResponse {
            status,
            headers,
            body: String::from_utf8_lossy(&bytes).into_owned(),
        })
    }
}

/// Stores Google credentials in a file only the current user can read.
pub struct FileCredentialStore {
    path: PathBuf,
}

impl FileCredentialStore {
    pub fn new(path: impl Into<PathBuf>) -> Self {
        Self { path: path.into() }
    }
}

impl BWGoogleCredentialStore for FileCredentialStore {
    fn load_credentials(&self) -> Option<String> {
        fs::read_to_string(&self.path).ok()
    }

    fn save_credentials(&self, credentials: String) -> Result<(), String> {
        let parent = self
            .path
            .parent()
            .ok_or_else(|| "The credentials path has no parent folder.".to_string())?;
        fs::create_dir_all(parent)
            .map_err(|error| format!("Could not save the Google sign-in: {error}"))?;
        let temporary = parent.join(format!(
            ".google-credentials.{}.tmp",
            uuid::Uuid::new_v4().simple()
        ));
        let result = (|| {
            let mut options = OpenOptions::new();
            options.write(true).create_new(true);
            #[cfg(unix)]
            {
                use std::os::unix::fs::OpenOptionsExt;
                options.mode(0o600);
            }
            let mut file = options
                .open(&temporary)
                .map_err(|error| format!("Could not save the Google sign-in: {error}"))?;
            file.write_all(credentials.as_bytes())
                .and_then(|_| file.sync_all())
                .map_err(|error| format!("Could not save the Google sign-in: {error}"))?;
            fs::rename(&temporary, &self.path)
                .map_err(|error| format!("Could not save the Google sign-in: {error}"))
        })();
        if result.is_err() {
            let _ = fs::remove_file(&temporary);
        }
        result
    }

    fn delete_credentials(&self) {
        let _ = fs::remove_file(&self.path);
    }
}

/// Google Drive configuration for a desktop build. The OAuth "Desktop app"
/// client comes from `BUDGET_WARDEN_GOOGLE_CLIENT_ID` and
/// `BUDGET_WARDEN_GOOGLE_CLIENT_SECRET`, read at run time and otherwise
/// baked in at compile time.
pub fn desktop_google_config(cache_directory: &Path) -> BWGoogleDriveConfig {
    let setting = |runtime: Option<String>, compiled: Option<&str>| {
        runtime
            .or_else(|| compiled.map(str::to_string))
            .map(|value| value.trim().to_string())
            .filter(|value| !value.is_empty())
    };
    BWGoogleDriveConfig {
        client_id: setting(
            std::env::var("BUDGET_WARDEN_GOOGLE_CLIENT_ID").ok(),
            option_env!("BUDGET_WARDEN_GOOGLE_CLIENT_ID"),
        )
        .unwrap_or_default(),
        client_secret: setting(
            std::env::var("BUDGET_WARDEN_GOOGLE_CLIENT_SECRET").ok(),
            option_env!("BUDGET_WARDEN_GOOGLE_CLIENT_SECRET"),
        ),
        cache_directory: cache_directory.to_string_lossy().into_owned(),
        folder_name: "Budget Warden".to_string(),
    }
}

/// Opens `url` in the user's browser.
pub fn open_in_browser(url: &str) -> Result<(), String> {
    let mut command = if cfg!(target_os = "macos") {
        std::process::Command::new("open")
    } else if cfg!(target_os = "windows") {
        let mut command = std::process::Command::new("rundll32");
        command.arg("url.dll,FileProtocolHandler");
        command
    } else {
        std::process::Command::new("xdg-open")
    };
    command
        .arg(url)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .spawn()
        .map(|_| ())
        .map_err(|error| format!("Could not open a browser: {error}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn file_credentials_are_private_and_removable() {
        let directory =
            std::env::temp_dir().join(format!("bw-credentials-{}", uuid::Uuid::new_v4().simple()));
        let store = FileCredentialStore::new(directory.join("google.json"));
        assert_eq!(store.load_credentials(), None);
        store.save_credentials("{\"a\":1}".into()).unwrap();
        store.save_credentials("{\"a\":2}".into()).unwrap();
        assert_eq!(store.load_credentials().as_deref(), Some("{\"a\":2}"));
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mode = fs::metadata(directory.join("google.json"))
                .unwrap()
                .permissions()
                .mode();
            assert_eq!(mode & 0o777, 0o600);
        }
        store.delete_credentials();
        assert_eq!(store.load_credentials(), None);
        let _ = fs::remove_dir_all(directory);
    }

    /// Reaches the real Drive API: `cargo test --features native-http -- --ignored`.
    #[test]
    #[ignore]
    fn native_client_reaches_google_drive() {
        let response = NativeHttpClient::new()
            .execute(BWHttpRequest::new(
                "GET",
                "https://www.googleapis.com/drive/v3/about?fields=user",
            ))
            .unwrap();
        assert_eq!(response.status, 401);
        assert!(response.body.contains("error"));
    }
}
