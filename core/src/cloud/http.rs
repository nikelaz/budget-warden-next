/*
 * Budget Warden
 * Copyright (c) 2026 Lazarov & Co EOOD
 * Author: Nikola Lazarov
 *
 * Licensed under the Source-Available Educational License.
 * See the LICENSE file in the project root for full terms.
 */

//! HTTP plumbing shared by the cloud providers.
//!
//! The core never opens TLS connections itself on mobile and Windows: the host
//! app performs each request through [`BWHttpClient`] with its platform HTTP
//! stack, so proxies, certificate trust, and network policy behave as the
//! platform expects. Rust hosts (Linux and the CLI) can use the `ureq` client
//! from `cloud::native` behind the `native-http` feature.

use boltffi::*;

/// One HTTP header.
#[data]
#[derive(Clone, Debug, PartialEq)]
pub struct BWHttpHeader {
    pub name: String,
    pub value: String,
}

/// A request the host performs on the core's behalf.
#[data]
#[derive(Clone, Debug, PartialEq)]
pub struct BWHttpRequest {
    /// `GET`, `POST`, `PATCH`, or `DELETE`.
    pub method: String,
    pub url: String,
    pub headers: Vec<BWHttpHeader>,
    /// UTF-8 request body. Every body the core sends is text.
    pub body: Option<String>,
}

/// The host's answer to a [`BWHttpRequest`]. Non-2xx statuses are responses,
/// not errors; return `Err` only when no response arrived (offline, DNS, TLS).
#[data]
#[derive(Clone, Debug, PartialEq)]
pub struct BWHttpResponse {
    pub status: i32,
    pub headers: Vec<BWHttpHeader>,
    /// Response body decoded as UTF-8 (lossy for binary bodies).
    pub body: String,
}

/// Performs HTTP requests for the core. Called from background threads only.
#[export]
pub trait BWHttpClient: Send + Sync {
    fn execute(&self, request: BWHttpRequest) -> Result<BWHttpResponse, String>;
}

impl BWHttpRequest {
    pub(crate) fn new(method: &str, url: impl Into<String>) -> Self {
        Self {
            method: method.to_string(),
            url: url.into(),
            headers: Vec::new(),
            body: None,
        }
    }

    pub(crate) fn header(mut self, name: &str, value: impl Into<String>) -> Self {
        self.headers.push(BWHttpHeader {
            name: name.to_string(),
            value: value.into(),
        });
        self
    }

    pub(crate) fn body(mut self, content_type: &str, body: impl Into<String>) -> Self {
        self = self.header("Content-Type", content_type);
        self.body = Some(body.into());
        self
    }

    #[cfg(test)]
    pub(crate) fn header_value(&self, name: &str) -> Option<&str> {
        find_header(&self.headers, name)
    }
}

impl BWHttpResponse {
    pub(crate) fn is_success(&self) -> bool {
        (200..300).contains(&self.status)
    }

    pub(crate) fn json(&self) -> Result<serde_json::Value, String> {
        serde_json::from_str(&self.body)
            .map_err(|error| format!("The server sent an unreadable response: {error}"))
    }
}

#[cfg(test)]
pub(crate) fn find_header<'a>(headers: &'a [BWHttpHeader], name: &str) -> Option<&'a str> {
    headers
        .iter()
        .find(|header| header.name.eq_ignore_ascii_case(name))
        .map(|header| header.value.as_str())
}

/// Percent-encodes `value` for use in a URL query or form body.
pub(crate) fn encode_component(value: &str) -> String {
    let mut encoded = String::with_capacity(value.len());
    for byte in value.bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                encoded.push(byte as char)
            }
            _ => encoded.push_str(&format!("%{byte:02X}")),
        }
    }
    encoded
}

/// Decodes a percent-encoded query component, treating `+` as a space.
pub(crate) fn decode_component(value: &str) -> String {
    let bytes = value.as_bytes();
    let mut decoded = Vec::with_capacity(bytes.len());
    let mut index = 0;
    while index < bytes.len() {
        match bytes[index] {
            b'+' => decoded.push(b' '),
            b'%' if index + 2 < bytes.len() => {
                let hex = std::str::from_utf8(&bytes[index + 1..index + 3]).unwrap_or("");
                match u8::from_str_radix(hex, 16) {
                    Ok(byte) => {
                        decoded.push(byte);
                        index += 2;
                    }
                    Err(_) => decoded.push(b'%'),
                }
            }
            byte => decoded.push(byte),
        }
        index += 1;
    }
    String::from_utf8_lossy(&decoded).into_owned()
}

/// Encodes key/value pairs as `application/x-www-form-urlencoded` or a query.
pub(crate) fn encode_pairs(pairs: &[(&str, &str)]) -> String {
    pairs
        .iter()
        .map(|(key, value)| format!("{}={}", encode_component(key), encode_component(value)))
        .collect::<Vec<_>>()
        .join("&")
}

/// Query parameters of `url` (after `?`, before `#`), decoded.
pub(crate) fn query_pairs(url: &str) -> Vec<(String, String)> {
    let Some((_, query)) = url.split_once('?') else {
        return Vec::new();
    };
    let query = query.split('#').next().unwrap_or("");
    query
        .split('&')
        .filter(|pair| !pair.is_empty())
        .map(|pair| {
            let (key, value) = pair.split_once('=').unwrap_or((pair, ""));
            (decode_component(key), decode_component(value))
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn components_round_trip_through_percent_encoding() {
        let value = "a b&c=d/é+%";
        let encoded = encode_component(value);
        assert_eq!(encoded, "a%20b%26c%3Dd%2F%C3%A9%2B%25");
        assert_eq!(decode_component(&encoded), value);
        assert_eq!(decode_component("a+b%zz%"), "a b%zz%");
    }

    #[test]
    fn query_pairs_are_decoded_and_fragment_is_ignored() {
        let pairs = query_pairs("http://127.0.0.1:1/cb?code=4%2F0A&state=x+y#frag");
        assert_eq!(
            pairs,
            vec![
                ("code".to_string(), "4/0A".to_string()),
                ("state".to_string(), "x y".to_string())
            ]
        );
        assert!(query_pairs("http://host/path").is_empty());
    }
}
