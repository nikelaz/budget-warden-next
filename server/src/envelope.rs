//! Validation for encrypted cloud budget envelopes.
//!
//! The service stores and returns envelopes without decrypting them. It checks
//! the declared metadata, algorithm suite, base64 field sizes, and byte bounds.
//! Budget contents, including the title, stay inside the ciphertext.

use axum::http::StatusCode;
use base64::{Engine as _, engine::general_purpose::STANDARD};
use serde::{Deserialize, Serialize};
use serde_json::json;
use uuid::Uuid;

use crate::errors::{ApiError, ApiResult};

/// XChaCha20-Poly1305 for snapshots, X25519 key agreement for device wrapping.
pub const SUITE_ID: &str = "xchacha20poly1305-x25519-v1";
pub const ENVELOPE_VERSION: u32 = 1;
pub const SUPPORTED_ENVELOPE_VERSIONS: [u32; 1] = [ENVELOPE_VERSION];

const NONCE_BYTES: usize = 24;
const TAG_BYTES: usize = 16;
const DATA_KEY_BYTES: usize = 32;
const WRAPPED_DATA_KEY_BYTES: usize = DATA_KEY_BYTES + TAG_BYTES;

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Envelope {
    pub envelope_version: u32,
    pub suite: String,
    pub portable_budget_id: Uuid,
    pub schema_version: i32,
    pub nonce: String,
    pub ciphertext: String,
    pub wrapped_data_key: WrappedDataKey,
}

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct WrappedDataKey {
    pub nonce: String,
    pub ciphertext: String,
}

pub struct ValidatedEnvelope {
    pub portable_budget_id: Uuid,
    pub schema_version: i32,
    /// Canonical JSON stored and returned by the service.
    pub json: String,
    pub bytes: i64,
}

pub fn validate(raw: &str, max_bytes: usize) -> ApiResult<ValidatedEnvelope> {
    let envelope: Envelope = serde_json::from_str(raw).map_err(invalid_envelope)?;
    if !SUPPORTED_ENVELOPE_VERSIONS.contains(&envelope.envelope_version)
        || envelope.suite != SUITE_ID
    {
        return Err(ApiError::new(
            StatusCode::UNPROCESSABLE_ENTITY,
            "envelope_unsupported",
            "This encrypted envelope version or suite is not supported by the service.",
        )
        .with_details(json!({
            "received_envelope_version": envelope.envelope_version,
            "received_suite": envelope.suite,
            "supported_envelope_versions": SUPPORTED_ENVELOPE_VERSIONS,
            "supported_suites": [SUITE_ID]
        })));
    }
    if envelope.schema_version < 1 {
        return Err(invalid_envelope(
            "schema_version must be a positive integer",
        ));
    }
    expect_len(&envelope.nonce, "nonce", NONCE_BYTES)?;
    let ciphertext = decode(&envelope.ciphertext, "ciphertext")?;
    if ciphertext.len() < TAG_BYTES {
        return Err(invalid_envelope(
            "ciphertext must include an authentication tag",
        ));
    }
    expect_len(
        &envelope.wrapped_data_key.nonce,
        "wrapped_data_key.nonce",
        NONCE_BYTES,
    )?;
    expect_len(
        &envelope.wrapped_data_key.ciphertext,
        "wrapped_data_key.ciphertext",
        WRAPPED_DATA_KEY_BYTES,
    )?;

    let json = serde_json::to_string(&envelope).map_err(ApiError::internal)?;
    if json.len() > max_bytes {
        return Err(ApiError::new(
            StatusCode::PAYLOAD_TOO_LARGE,
            "snapshot_too_large",
            "The encrypted snapshot exceeds the configured byte limit.",
        )
        .with_details(json!({ "maximum_bytes": max_bytes })));
    }
    let bytes = i64::try_from(json.len()).map_err(|_| {
        ApiError::internal("envelope size does not fit a signed 64-bit storage count")
    })?;
    Ok(ValidatedEnvelope {
        portable_budget_id: envelope.portable_budget_id,
        schema_version: envelope.schema_version,
        json,
        bytes,
    })
}

fn decode(value: &str, field: &str) -> ApiResult<Vec<u8>> {
    STANDARD
        .decode(value)
        .map_err(|_| invalid_envelope(format!("{field} must be standard base64")))
}

fn expect_len(value: &str, field: &str, expected: usize) -> ApiResult<()> {
    let decoded = decode(value, field)?;
    if decoded.len() != expected {
        return Err(invalid_envelope(format!(
            "{field} must decode to {expected} bytes"
        )));
    }
    Ok(())
}

fn invalid_envelope(detail: impl std::fmt::Display) -> ApiError {
    ApiError::new(
        StatusCode::UNPROCESSABLE_ENTITY,
        "invalid_snapshot",
        detail.to_string(),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    const PORTABLE_ID: &str = "3f2a9c1e-5b7d-4e8a-9c21-7d4e5f6a8b90";

    fn b64(bytes: usize) -> String {
        STANDARD.encode(vec![7u8; bytes])
    }

    fn envelope_json(overrides: serde_json::Value) -> String {
        let mut value = json!({
            "envelope_version": ENVELOPE_VERSION,
            "suite": SUITE_ID,
            "portable_budget_id": PORTABLE_ID,
            "schema_version": 2,
            "nonce": b64(NONCE_BYTES),
            "ciphertext": b64(64),
            "wrapped_data_key": {
                "nonce": b64(NONCE_BYTES),
                "ciphertext": b64(WRAPPED_DATA_KEY_BYTES)
            }
        });
        if let (Some(base), Some(extra)) = (value.as_object_mut(), overrides.as_object()) {
            for (key, item) in extra {
                base.insert(key.clone(), item.clone());
            }
        }
        value.to_string()
    }

    fn code_of(result: ApiResult<ValidatedEnvelope>) -> &'static str {
        match result {
            Ok(_) => "ok",
            Err(error) => error.code,
        }
    }

    #[test]
    fn accepts_well_formed_envelope_and_exposes_routing_metadata() {
        let validated = validate(&envelope_json(json!({})), 1024 * 1024).unwrap();
        assert_eq!(validated.portable_budget_id.to_string(), PORTABLE_ID);
        assert_eq!(validated.schema_version, 2);
        assert!(validated.bytes > 0);
    }

    #[test]
    fn rejects_unknown_suite_and_envelope_version() {
        assert_eq!(
            code_of(validate(
                &envelope_json(json!({ "suite": "plaintext" })),
                1024 * 1024
            )),
            "envelope_unsupported"
        );
        assert_eq!(
            code_of(validate(
                &envelope_json(json!({ "envelope_version": 99 })),
                1024 * 1024
            )),
            "envelope_unsupported"
        );
    }

    #[test]
    fn rejects_plaintext_snapshots_and_unknown_fields() {
        let plaintext =
            r#"{"id":"3f2a9c1e-5b7d-4e8a-9c21-7d4e5f6a8b90","schema_version":2,"title":"Home"}"#;
        assert_eq!(
            code_of(validate(plaintext, 1024 * 1024)),
            "invalid_snapshot"
        );
        assert_eq!(
            code_of(validate(
                &envelope_json(json!({ "title": "Home" })),
                1024 * 1024
            )),
            "invalid_snapshot"
        );
    }

    #[test]
    fn rejects_bad_nonce_tag_and_wrapped_key_sizes() {
        assert_eq!(
            code_of(validate(
                &envelope_json(json!({ "nonce": b64(12) })),
                1024 * 1024
            )),
            "invalid_snapshot"
        );
        assert_eq!(
            code_of(validate(
                &envelope_json(json!({ "ciphertext": b64(8) })),
                1024 * 1024
            )),
            "invalid_snapshot"
        );
        assert_eq!(
            code_of(validate(
                &envelope_json(
                    json!({ "wrapped_data_key": { "nonce": b64(NONCE_BYTES), "ciphertext": b64(32) } })
                ),
                1024 * 1024
            )),
            "invalid_snapshot"
        );
    }

    #[test]
    fn enforces_byte_limit_and_non_positive_schema() {
        assert_eq!(
            code_of(validate(&envelope_json(json!({})), 64)),
            "snapshot_too_large"
        );
        assert_eq!(
            code_of(validate(
                &envelope_json(json!({ "schema_version": 0 })),
                1024 * 1024
            )),
            "invalid_snapshot"
        );
    }
}
