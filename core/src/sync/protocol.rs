//! Encrypted snapshot envelope shared by the client and the cloud service.

use serde::{Deserialize, Serialize};
use uuid::Uuid;

/// XChaCha20-Poly1305 snapshots, X25519 device key agreement, HKDF-SHA256.
pub const SUITE_ID: &str = "xchacha20poly1305-x25519-v1";
pub const ENVELOPE_VERSION: u32 = 1;

/// Client-encrypted cloud snapshot. Routing metadata stays in cleartext and is
/// bound into the AEAD associated data, so it cannot be changed unnoticed.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct BudgetEnvelope {
    pub envelope_version: u32,
    pub suite: String,
    pub portable_budget_id: Uuid,
    pub schema_version: i32,
    /// Standard base64 of 24 bytes.
    pub nonce: String,
    /// Standard base64 of AEAD output, including the 16-byte tag.
    pub ciphertext: String,
    pub wrapped_data_key: WrappedDataKey,
}

/// The per-budget data key, encrypted under the account vault key.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct WrappedDataKey {
    /// Standard base64 of 24 bytes.
    pub nonce: String,
    /// Standard base64 of 32 key bytes plus the 16-byte tag.
    pub ciphertext: String,
}
