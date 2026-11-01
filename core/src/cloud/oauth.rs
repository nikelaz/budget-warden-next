/*
 * Budget Warden
 * Copyright (c) 2026 Lazarov & Co EOOD
 * Author: Nikola Lazarov
 *
 * Licensed under the Source-Available Educational License.
 * See the LICENSE file in the project root for full terms.
 */

//! Google OAuth 2.0 for installed apps: authorization code flow with PKCE.
//!
//! Apple apps receive the redirect through `ASWebAuthenticationSession`;
//! desktop apps use [`BWGoogleLoopbackReceiver`], which listens on
//! `127.0.0.1` for the browser's redirect. Android does not use this module:
//! Google Play services hands it access tokens directly.

use std::io::{BufRead, BufReader, Write};
use std::net::{TcpListener, TcpStream};
use std::sync::Mutex;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use boltffi::*;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use uuid::Uuid;

use super::http::{BWHttpClient, BWHttpRequest, encode_pairs, query_pairs};
use super::{AUTH_REQUIRED_PREFIX, auth_required};

pub(crate) const AUTHORIZATION_ENDPOINT: &str = "https://accounts.google.com/o/oauth2/v2/auth";
pub(crate) const TOKEN_ENDPOINT: &str = "https://oauth2.googleapis.com/token";
pub(crate) const REVOCATION_ENDPOINT: &str = "https://oauth2.googleapis.com/revoke";

/// Access to files Budget Warden created and files the user chose for it in
/// the Google Picker (see `picker/`). A non-sensitive scope, so it needs no
/// restricted-scope verification; budgets shared by others are added through
/// the picker instead of being listed automatically.
pub const GOOGLE_DRIVE_SCOPE: &str = "https://www.googleapis.com/auth/drive.file";

/// Refresh access tokens this long before Google says they expire.
const EXPIRY_MARGIN_MS: i64 = 60_000;

/// Tokens and account details persisted by the host's credential store.
#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq)]
pub(crate) struct StoredCredentials {
    #[serde(default)]
    pub refresh_token: Option<String>,
    #[serde(default)]
    pub access_token: Option<String>,
    #[serde(default)]
    pub expires_at_ms: i64,
    #[serde(default)]
    pub email: Option<String>,
    #[serde(default)]
    pub display_name: Option<String>,
}

impl StoredCredentials {
    pub fn decode(json: &str) -> Option<Self> {
        serde_json::from_str(json).ok()
    }

    pub fn encode(&self) -> String {
        serde_json::to_string(self).unwrap_or_default()
    }

    pub fn valid_access_token(&self, now_ms: i64) -> Option<&str> {
        self.access_token
            .as_deref()
            .filter(|_| self.expires_at_ms - EXPIRY_MARGIN_MS > now_ms)
    }
}

/// A sign-in the host must complete in a browser.
#[data]
#[derive(Clone, Debug, PartialEq)]
pub struct BWGoogleSignInRequest {
    /// Open this URL in the system browser or an authentication session.
    pub authorization_url: String,
    /// The redirect URI the browser returns to.
    pub redirect_uri: String,
    /// Opaque value echoed by Google; the core checks it.
    pub state: String,
}

pub(crate) struct PendingSignIn {
    pub state: String,
    pub code_verifier: String,
    pub redirect_uri: String,
}

pub(crate) fn now_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_millis() as i64)
        .unwrap_or(0)
}

/// A PKCE verifier: 64 characters from the unreserved set.
pub(crate) fn new_code_verifier() -> String {
    format!("{}{}", Uuid::new_v4().simple(), Uuid::new_v4().simple())
}

/// The S256 challenge for `verifier` (RFC 7636).
pub(crate) fn code_challenge(verifier: &str) -> String {
    base64_url(&Sha256::digest(verifier.as_bytes()))
}

fn base64_url(bytes: &[u8]) -> String {
    const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    let mut output = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for chunk in bytes.chunks(3) {
        let value = (u32::from(chunk[0]) << 16)
            | (u32::from(*chunk.get(1).unwrap_or(&0)) << 8)
            | u32::from(*chunk.get(2).unwrap_or(&0));
        let symbols = chunk.len() + 1;
        for index in 0..symbols {
            output.push(ALPHABET[((value >> (18 - 6 * index)) & 0x3f) as usize] as char);
        }
    }
    output
}

pub(crate) fn authorization_url(
    client_id: &str,
    redirect_uri: &str,
    scope: &str,
    state: &str,
    code_verifier: &str,
    login_hint: Option<&str>,
) -> String {
    let challenge = code_challenge(code_verifier);
    let mut pairs = vec![
        ("client_id", client_id),
        ("redirect_uri", redirect_uri),
        ("response_type", "code"),
        ("scope", scope),
        ("state", state),
        ("code_challenge", challenge.as_str()),
        ("code_challenge_method", "S256"),
        // A refresh token lets the app sync without asking again.
        ("access_type", "offline"),
        ("prompt", "consent"),
        ("include_granted_scopes", "true"),
    ];
    if let Some(hint) = login_hint {
        pairs.push(("login_hint", hint));
    }
    format!("{AUTHORIZATION_ENDPOINT}?{}", encode_pairs(&pairs))
}

/// Extracts the authorization code from a redirect URL, checking `state`.
pub(crate) fn authorization_code(
    callback_url: &str,
    expected_state: &str,
) -> Result<String, String> {
    let pairs = query_pairs(callback_url);
    let value = |name: &str| {
        pairs
            .iter()
            .find(|(key, _)| key == name)
            .map(|(_, value)| value.clone())
    };
    if let Some(error) = value("error") {
        return Err(if error == "access_denied" {
            "Google sign-in was cancelled.".to_string()
        } else {
            format!("Google sign-in failed: {error}")
        });
    }
    if value("state").as_deref() != Some(expected_state) {
        return Err(
            "Google sign-in returned an unexpected response. Please try again.".to_string(),
        );
    }
    value("code")
        .filter(|code| !code.is_empty())
        .ok_or_else(|| "Google sign-in did not return an authorization code.".to_string())
}

#[derive(Deserialize)]
struct TokenResponse {
    access_token: String,
    #[serde(default)]
    expires_in: i64,
    #[serde(default)]
    refresh_token: Option<String>,
}

#[derive(Deserialize)]
struct TokenError {
    #[serde(default)]
    error: String,
    #[serde(default)]
    error_description: Option<String>,
}

pub(crate) struct TokenGrant {
    pub access_token: String,
    pub expires_at_ms: i64,
    pub refresh_token: Option<String>,
}

/// Exchanges an authorization code or refresh token at the token endpoint.
pub(crate) fn request_token(
    http: &dyn BWHttpClient,
    client_id: &str,
    client_secret: Option<&str>,
    grant: &[(&str, &str)],
) -> Result<TokenGrant, String> {
    let mut pairs: Vec<(&str, &str)> = grant.to_vec();
    pairs.push(("client_id", client_id));
    if let Some(secret) = client_secret.filter(|secret| !secret.is_empty()) {
        pairs.push(("client_secret", secret));
    }
    let request = BWHttpRequest::new("POST", TOKEN_ENDPOINT)
        .header("Accept", "application/json")
        .body("application/x-www-form-urlencoded", encode_pairs(&pairs));
    let response = http.execute(request)?;
    if !response.is_success() {
        let error: TokenError = serde_json::from_str(&response.body).unwrap_or(TokenError {
            error: format!("HTTP {}", response.status),
            error_description: None,
        });
        if error.error == "invalid_grant" {
            return Err(auth_required(
                "Your Google sign-in expired. Sign in to Google Drive again.",
            ));
        }
        return Err(format!(
            "Google rejected the sign-in: {}",
            error.error_description.unwrap_or(error.error)
        ));
    }
    let token: TokenResponse = serde_json::from_str(&response.body)
        .map_err(|error| format!("Google sent an unreadable token response: {error}"))?;
    Ok(TokenGrant {
        access_token: token.access_token,
        expires_at_ms: now_ms() + token.expires_in.max(0) * 1000,
        refresh_token: token.refresh_token,
    })
}

pub(crate) fn revoke(http: &dyn BWHttpClient, token: &str) {
    let request = BWHttpRequest::new("POST", REVOCATION_ENDPOINT).body(
        "application/x-www-form-urlencoded",
        encode_pairs(&[("token", token)]),
    );
    let _ = http.execute(request);
}

/// Receives a desktop OAuth redirect on a loopback port (RFC 8252 §7.3).
pub struct BWGoogleLoopbackReceiver {
    listener: Mutex<Option<TcpListener>>,
}

impl Default for BWGoogleLoopbackReceiver {
    fn default() -> Self {
        Self::new()
    }
}

const LOOPBACK_SUCCESS_PAGE: &str = "<!doctype html><html><head><meta charset=\"utf-8\"><title>Budget Warden</title></head><body style=\"font-family:system-ui;text-align:center;padding:3em\"><h1>All set</h1><p>You can close this window and return to Budget Warden.</p></body></html>";

/// Query parameters that mark a browser request as the result the receiver
/// waits for: an OAuth redirect, or the shared-budget picker's answer.
const RESULT_PARAMETERS: [&str; 4] = ["code", "error", "ids", "cancelled"];

#[export]
impl BWGoogleLoopbackReceiver {
    pub fn new() -> Self {
        Self {
            listener: Mutex::new(None),
        }
    }

    /// Starts listening on a free loopback port and returns the redirect URI
    /// to pass to `BWGoogleDrive::begin_sign_in`.
    pub fn start(&self) -> Result<String, String> {
        let listener = TcpListener::bind("127.0.0.1:0")
            .map_err(|error| format!("Could not prepare Google sign-in: {error}"))?;
        let port = listener
            .local_addr()
            .map_err(|error| format!("Could not prepare Google sign-in: {error}"))?
            .port();
        *self
            .listener
            .lock()
            .map_err(|_| "Sign-in state is unavailable.".to_string())? = Some(listener);
        Ok(format!("http://127.0.0.1:{port}"))
    }

    /// Waits for the browser to return and gives back the full redirect URL,
    /// to pass to `BWGoogleDrive::complete_sign_in`.
    pub fn wait_for_redirect(&self, timeout_seconds: i32) -> Result<String, String> {
        let listener = self
            .listener
            .lock()
            .map_err(|_| "Sign-in state is unavailable.".to_string())?
            .take()
            .ok_or_else(|| "Google sign-in has not started.".to_string())?;
        listener
            .set_nonblocking(true)
            .map_err(|error| format!("Could not wait for Google sign-in: {error}"))?;
        let deadline = Instant::now() + Duration::from_secs(timeout_seconds.max(1) as u64);
        let port = listener
            .local_addr()
            .map(|address| address.port())
            .unwrap_or(0);
        while Instant::now() < deadline {
            match listener.accept() {
                Ok((stream, _)) => {
                    if let Some(target) = answer_redirect(stream) {
                        return Ok(format!("http://127.0.0.1:{port}{target}"));
                    }
                }
                Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                    std::thread::sleep(Duration::from_millis(100));
                }
                Err(error) => return Err(format!("Google sign-in was interrupted: {error}")),
            }
        }
        Err("Google sign-in timed out. Please try again.".to_string())
    }

    /// Stops waiting, for example when the user cancels sign-in.
    pub fn cancel(&self) {
        if let Ok(mut listener) = self.listener.lock() {
            listener.take();
        }
    }
}

/// Serves one browser request. Returns its request target when it carries
/// a result; other requests (such as `/favicon.ico`) get a 404.
fn answer_redirect(mut stream: TcpStream) -> Option<String> {
    let _ = stream.set_nonblocking(false);
    let _ = stream.set_read_timeout(Some(Duration::from_secs(5)));
    let mut reader = BufReader::new(stream.try_clone().ok()?);
    let mut request_line = String::new();
    reader.read_line(&mut request_line).ok()?;
    // Drain headers so the browser sees a well-formed exchange.
    loop {
        let mut line = String::new();
        match reader.read_line(&mut line) {
            Ok(0) => break,
            Ok(_) if line == "\r\n" || line == "\n" => break,
            Ok(_) => continue,
            Err(_) => break,
        }
    }
    let target = request_line
        .split_whitespace()
        .nth(1)
        .unwrap_or("/")
        .to_string();
    let carries_result = query_pairs(&target)
        .iter()
        .any(|(key, _)| RESULT_PARAMETERS.contains(&key.as_str()));
    let (status, body) = if carries_result {
        ("200 OK", LOOPBACK_SUCCESS_PAGE)
    } else {
        ("404 Not Found", "")
    };
    let _ = write!(
        stream,
        "HTTP/1.1 {status}\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
        body.len()
    );
    let _ = stream.flush();
    carries_result.then_some(target)
}

/// Whether `message` is a core error that asks the user to sign in again.
#[export]
pub fn is_cloud_sign_in_required(message: String) -> bool {
    message.starts_with(AUTH_REQUIRED_PREFIX)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pkce_challenge_matches_rfc_7636_example() {
        assert_eq!(
            code_challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
            "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
        );
        let verifier = new_code_verifier();
        assert_eq!(verifier.len(), 64);
        assert!(verifier.chars().all(|c| c.is_ascii_alphanumeric()));
    }

    #[test]
    fn authorization_url_requests_offline_pkce_access() {
        let url = authorization_url(
            "client.apps",
            "http://127.0.0.1:5000",
            GOOGLE_DRIVE_SCOPE,
            "s1",
            "v",
            None,
        );
        let pairs = query_pairs(&url);
        let get = |name: &str| {
            pairs
                .iter()
                .find(|(k, _)| k == name)
                .map(|(_, v)| v.as_str())
        };
        assert!(url.starts_with(AUTHORIZATION_ENDPOINT));
        assert_eq!(get("client_id"), Some("client.apps"));
        assert_eq!(get("redirect_uri"), Some("http://127.0.0.1:5000"));
        assert_eq!(get("scope"), Some(GOOGLE_DRIVE_SCOPE));
        assert_eq!(get("code_challenge_method"), Some("S256"));
        assert_eq!(get("code_challenge"), Some(code_challenge("v").as_str()));
        assert_eq!(get("access_type"), Some("offline"));
    }

    #[test]
    fn authorization_code_checks_state_and_errors() {
        assert_eq!(
            authorization_code("x:/cb?state=a&code=c1", "a").unwrap(),
            "c1"
        );
        assert!(authorization_code("x:/cb?state=b&code=c1", "a").is_err());
        assert_eq!(
            authorization_code("x:/cb?error=access_denied&state=a", "a").unwrap_err(),
            "Google sign-in was cancelled."
        );
    }

    #[test]
    fn loopback_receiver_returns_the_redirect_and_ignores_other_requests() {
        let receiver = BWGoogleLoopbackReceiver::new();
        let redirect = receiver.start().unwrap();
        let address = redirect.trim_start_matches("http://").to_string();
        let client = std::thread::spawn(move || {
            let mut favicon = TcpStream::connect(&address).unwrap();
            favicon
                .write_all(b"GET /favicon.ico HTTP/1.1\r\nHost: x\r\n\r\n")
                .unwrap();
            let mut answer = String::new();
            let _ = std::io::Read::read_to_string(&mut favicon, &mut answer);
            assert!(answer.starts_with("HTTP/1.1 404"));
            let mut stream = TcpStream::connect(&address).unwrap();
            stream
                .write_all(b"GET /?state=s&code=abc HTTP/1.1\r\nHost: x\r\n\r\n")
                .unwrap();
            let mut answer = String::new();
            let _ = std::io::Read::read_to_string(&mut stream, &mut answer);
            answer
        });
        let url = receiver.wait_for_redirect(10).unwrap();
        assert_eq!(authorization_code(&url, "s").unwrap(), "abc");
        assert!(client.join().unwrap().contains("All set"));

        // The picker's answer is accepted the same way.
        let redirect = receiver.start().unwrap();
        let address = redirect.trim_start_matches("http://").to_string();
        let client = std::thread::spawn(move || {
            let mut stream = TcpStream::connect(&address).unwrap();
            stream
                .write_all(b"GET /picked?ids=f1,f2 HTTP/1.1\r\nHost: x\r\n\r\n")
                .unwrap();
            let mut answer = String::new();
            let _ = std::io::Read::read_to_string(&mut stream, &mut answer);
        });
        let url = receiver.wait_for_redirect(10).unwrap();
        client.join().unwrap();
        assert!(url.ends_with("/picked?ids=f1,f2"));
    }

    #[test]
    fn stored_credentials_round_trip_and_expire_early() {
        let credentials = StoredCredentials {
            refresh_token: Some("r".into()),
            access_token: Some("a".into()),
            expires_at_ms: 1_000_000,
            email: Some("me@example.com".into()),
            display_name: None,
        };
        assert_eq!(
            StoredCredentials::decode(&credentials.encode()),
            Some(credentials.clone())
        );
        assert_eq!(credentials.valid_access_token(900_000), Some("a"));
        assert_eq!(credentials.valid_access_token(950_000), None);
    }
}
