/*
 * Budget Warden
 * Copyright (c) 2026 Lazarov & Co EOOD
 * Author: Nikola Lazarov
 *
 * Licensed under the Source-Available Educational License.
 * See the LICENSE file in the project root for full terms.
 */

//! Google Drive REST v3 requests and responses used by cloud budgets.

use serde::{Deserialize, Serialize};
use serde_json::json;
use uuid::Uuid;

use super::http::{BWHttpRequest, BWHttpResponse, encode_pairs};

pub(crate) const API_ROOT: &str = "https://www.googleapis.com/drive/v3";
pub(crate) const UPLOAD_ROOT: &str = "https://www.googleapis.com/upload/drive/v3";

/// MIME type of `.budget` files, matching the Apple and Android declarations.
pub const BUDGET_MIME_TYPE: &str = "application/vnd.lazarovco.budgetwarden.budget";
const FOLDER_MIME_TYPE: &str = "application/vnd.google-apps.folder";
/// Private app property that marks files Budget Warden uploaded. App
/// properties are visible to this app for every user a file is shared with.
const APP_PROPERTY_KEY: &str = "budgetWarden";
const APP_PROPERTY_VALUE: &str = "budget";

pub(crate) const FILE_FIELDS: &str = "id,name,mimeType,version,modifiedTime,ownedByMe,shared,webViewLink,trashed,owners(displayName,emailAddress),sharingUser(displayName,emailAddress),capabilities(canEdit,canShare)";

#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub(crate) struct DriveUser {
    #[serde(default)]
    pub display_name: Option<String>,
    #[serde(default)]
    pub email_address: Option<String>,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub(crate) struct DriveCapabilities {
    #[serde(default)]
    pub can_edit: bool,
    #[serde(default)]
    pub can_share: bool,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub(crate) struct DriveFile {
    pub id: String,
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub mime_type: Option<String>,
    /// Drive encodes this int64 as a string. It changes on every change.
    #[serde(default)]
    pub version: Option<String>,
    #[serde(default)]
    pub modified_time: Option<String>,
    #[serde(default)]
    pub owned_by_me: Option<bool>,
    #[serde(default)]
    pub shared: Option<bool>,
    #[serde(default)]
    pub web_view_link: Option<String>,
    #[serde(default)]
    pub trashed: Option<bool>,
    #[serde(default)]
    pub owners: Vec<DriveUser>,
    #[serde(default)]
    pub sharing_user: Option<DriveUser>,
    #[serde(default)]
    pub capabilities: DriveCapabilities,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct FileList {
    #[serde(default)]
    files: Vec<DriveFile>,
    #[serde(default)]
    next_page_token: Option<String>,
}

#[derive(Clone, Debug, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub(crate) struct DrivePermission {
    pub id: String,
    #[serde(default, rename = "type")]
    pub kind: String,
    #[serde(default)]
    pub role: String,
    #[serde(default)]
    pub email_address: Option<String>,
    #[serde(default)]
    pub display_name: Option<String>,
    #[serde(default)]
    pub deleted: bool,
}

#[derive(Deserialize)]
struct PermissionList {
    #[serde(default)]
    permissions: Vec<DrivePermission>,
}

/// Quotes `value` as a Drive query string literal.
pub(crate) fn query_literal(value: &str) -> String {
    format!("'{}'", value.replace('\\', "\\\\").replace('\'', "\\'"))
}

pub(crate) fn budgets_query() -> String {
    format!(
        "trashed = false and (mimeType = {} or appProperties has {{ key={} and value={} }})",
        query_literal(BUDGET_MIME_TYPE),
        query_literal(APP_PROPERTY_KEY),
        query_literal(APP_PROPERTY_VALUE),
    )
}

pub(crate) fn list_files_request(query: &str, page_token: Option<&str>) -> BWHttpRequest {
    let fields = format!("nextPageToken,files({FILE_FIELDS})");
    let mut pairs = vec![
        ("q", query),
        ("fields", fields.as_str()),
        ("pageSize", "200"),
        ("spaces", "drive"),
        ("orderBy", "modifiedTime desc"),
    ];
    if let Some(token) = page_token {
        pairs.push(("pageToken", token));
    }
    BWHttpRequest::new("GET", format!("{API_ROOT}/files?{}", encode_pairs(&pairs)))
}

pub(crate) fn parse_file_list(response: &BWHttpResponse) -> Result<(Vec<DriveFile>, Option<String>), String> {
    let list: FileList = serde_json::from_str(&response.body)
        .map_err(|error| format!("Google Drive sent an unreadable file list: {error}"))?;
    Ok((list.files, list.next_page_token))
}

pub(crate) fn folder_query(name: &str) -> String {
    format!(
        "trashed = false and mimeType = {} and name = {} and 'root' in parents",
        query_literal(FOLDER_MIME_TYPE),
        query_literal(name),
    )
}

pub(crate) fn create_folder_request(name: &str) -> BWHttpRequest {
    let body = json!({ "name": name, "mimeType": FOLDER_MIME_TYPE, "parents": ["root"] });
    BWHttpRequest::new("POST", format!("{API_ROOT}/files?fields=id"))
        .body("application/json; charset=UTF-8", body.to_string())
}

pub(crate) fn metadata_request(file_id: &str) -> BWHttpRequest {
    BWHttpRequest::new(
        "GET",
        format!("{API_ROOT}/files/{}?{}", path_segment(file_id), encode_pairs(&[("fields", FILE_FIELDS)])),
    )
}

pub(crate) fn download_request(file_id: &str) -> BWHttpRequest {
    BWHttpRequest::new("GET", format!("{API_ROOT}/files/{}?alt=media", path_segment(file_id)))
}

/// A multipart upload that creates `name` in `folder_id` with `json` content.
pub(crate) fn create_file_request(name: &str, folder_id: &str, json: &str) -> BWHttpRequest {
    let metadata = json!({
        "name": name,
        "mimeType": BUDGET_MIME_TYPE,
        "parents": [folder_id],
        "appProperties": { APP_PROPERTY_KEY: APP_PROPERTY_VALUE },
    });
    let boundary = format!("bw-{}", Uuid::new_v4().simple());
    let body = format!(
        "--{boundary}\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n{metadata}\r\n--{boundary}\r\nContent-Type: {BUDGET_MIME_TYPE}\r\n\r\n{json}\r\n--{boundary}--\r\n"
    );
    BWHttpRequest::new(
        "POST",
        format!(
            "{UPLOAD_ROOT}/files?{}",
            encode_pairs(&[("uploadType", "multipart"), ("fields", FILE_FIELDS)])
        ),
    )
    .body(&format!("multipart/related; boundary={boundary}"), body)
}

/// Replaces the content of `file_id` with `json`.
pub(crate) fn update_content_request(file_id: &str, json: &str) -> BWHttpRequest {
    BWHttpRequest::new(
        "PATCH",
        format!(
            "{UPLOAD_ROOT}/files/{}?{}",
            path_segment(file_id),
            encode_pairs(&[("uploadType", "media"), ("fields", FILE_FIELDS)])
        ),
    )
    .body(BUDGET_MIME_TYPE, json.to_string())
}

pub(crate) fn about_request() -> BWHttpRequest {
    BWHttpRequest::new("GET", format!("{API_ROOT}/about?fields=user(displayName,emailAddress)"))
}

pub(crate) fn parse_about(response: &BWHttpResponse) -> Result<DriveUser, String> {
    let value = response.json()?;
    serde_json::from_value(value.get("user").cloned().unwrap_or_default())
        .map_err(|error| format!("Google Drive sent unreadable account details: {error}"))
}

pub(crate) fn create_permission_request(
    file_id: &str,
    email: &str,
    role: &str,
    message: Option<&str>,
) -> BWHttpRequest {
    let mut pairs = vec![
        ("sendNotificationEmail", "true"),
        ("fields", "id,type,role,emailAddress,displayName,deleted"),
    ];
    if let Some(message) = message.filter(|message| !message.trim().is_empty()) {
        pairs.push(("emailMessage", message));
    }
    let body = json!({ "type": "user", "role": role, "emailAddress": email });
    BWHttpRequest::new(
        "POST",
        format!("{API_ROOT}/files/{}/permissions?{}", path_segment(file_id), encode_pairs(&pairs)),
    )
    .body("application/json; charset=UTF-8", body.to_string())
}

pub(crate) fn list_permissions_request(file_id: &str) -> BWHttpRequest {
    BWHttpRequest::new(
        "GET",
        format!(
            "{API_ROOT}/files/{}/permissions?{}",
            path_segment(file_id),
            encode_pairs(&[(
                "fields",
                "permissions(id,type,role,emailAddress,displayName,deleted)"
            )])
        ),
    )
}

pub(crate) fn parse_permission(response: &BWHttpResponse) -> Result<DrivePermission, String> {
    serde_json::from_str(&response.body)
        .map_err(|error| format!("Google Drive sent an unreadable sharing response: {error}"))
}

pub(crate) fn parse_permissions(response: &BWHttpResponse) -> Result<Vec<DrivePermission>, String> {
    let list: PermissionList = serde_json::from_str(&response.body)
        .map_err(|error| format!("Google Drive sent an unreadable sharing list: {error}"))?;
    Ok(list.permissions.into_iter().filter(|permission| !permission.deleted).collect())
}

pub(crate) fn delete_permission_request(file_id: &str, permission_id: &str) -> BWHttpRequest {
    BWHttpRequest::new(
        "DELETE",
        format!(
            "{API_ROOT}/files/{}/permissions/{}",
            path_segment(file_id),
            path_segment(permission_id)
        ),
    )
}

pub(crate) fn parse_file(response: &BWHttpResponse) -> Result<DriveFile, String> {
    serde_json::from_str(&response.body)
        .map_err(|error| format!("Google Drive sent unreadable file details: {error}"))
}

/// A readable message for a failed Drive response.
pub(crate) fn error_message(response: &BWHttpResponse) -> String {
    let detail = response
        .json()
        .ok()
        .and_then(|value| {
            value
                .pointer("/error/message")
                .and_then(|message| message.as_str())
                .map(str::to_string)
        })
        .unwrap_or_default();
    match response.status {
        404 => "This budget is no longer available in Google Drive. It may have been deleted or unshared.".to_string(),
        403 if detail.is_empty() => "Google Drive denied access to this budget.".to_string(),
        403 => format!("Google Drive denied the request: {detail}"),
        429 => "Google Drive is busy. Please try again in a moment.".to_string(),
        status if detail.is_empty() => format!("Google Drive returned an error (HTTP {status})."),
        status => format!("Google Drive returned an error (HTTP {status}): {detail}"),
    }
}

/// Drive IDs are URL-safe, but encode them anyway so a malformed ID cannot
/// change the request path.
fn path_segment(value: &str) -> String {
    super::http::encode_component(value)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cloud::http::query_pairs;

    #[test]
    fn queries_quote_literals() {
        assert_eq!(query_literal("Bob's \\ budgets"), "'Bob\\'s \\\\ budgets'");
        assert!(budgets_query().contains("mimeType = 'application/vnd.lazarovco.budgetwarden.budget'"));
        assert!(folder_query("Budget Warden").contains("name = 'Budget Warden'"));
    }

    #[test]
    fn create_request_is_multipart_with_metadata_and_content() {
        let request = create_file_request("May.budget", "folder1", "{\"a\":1}");
        let content_type = request.header_value("Content-Type").unwrap().to_string();
        let boundary = content_type.split("boundary=").nth(1).unwrap();
        let body = request.body.unwrap();
        assert!(request.url.starts_with(UPLOAD_ROOT));
        assert!(query_pairs(&request.url).contains(&("uploadType".to_string(), "multipart".to_string())));
        let parts: Vec<&str> = body.split(&format!("--{boundary}")).collect();
        assert_eq!(parts.len(), 4);
        let metadata: serde_json::Value =
            serde_json::from_str(parts[1].split("\r\n\r\n").nth(1).unwrap().trim()).unwrap();
        assert_eq!(metadata["parents"][0], "folder1");
        assert_eq!(metadata["appProperties"]["budgetWarden"], "budget");
        assert!(parts[2].ends_with("{\"a\":1}\r\n"));
        assert_eq!(parts[3], "--\r\n");
    }

    #[test]
    fn error_messages_prefer_drive_details() {
        let response = BWHttpResponse {
            status: 403,
            headers: vec![],
            body: "{\"error\":{\"code\":403,\"message\":\"Rate limit\"}}".to_string(),
        };
        assert_eq!(error_message(&response), "Google Drive denied the request: Rate limit");
        let missing = BWHttpResponse { status: 404, headers: vec![], body: String::new() };
        assert!(error_message(&missing).contains("no longer available"));
    }
}
