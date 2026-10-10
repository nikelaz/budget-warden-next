//! Client-side encryption for cloud snapshots.
//!
//! Primitives come from RustCrypto (XChaCha20-Poly1305, HKDF-SHA256) and
//! dalek (X25519). The envelope layout, associated-data encoding, and key
//! hierarchy are Budget Warden's own and follow `docs/cloud-sync-encryption.md`.
//! This module has not had the independent review that document requires.

use base64::{Engine as _, engine::general_purpose::STANDARD};
use chacha20poly1305::{
    KeyInit, XChaCha20Poly1305, XNonce,
    aead::{Aead, Payload},
};
use hkdf::Hkdf;
use sha2::Sha256;
use uuid::Uuid;
use x25519_dalek::{PublicKey, StaticSecret};
use zeroize::{Zeroize, ZeroizeOnDrop};

use super::protocol::{BudgetEnvelope, ENVELOPE_VERSION, SUITE_ID, WrappedDataKey};

pub const KEY_BYTES: usize = 32;
const NONCE_BYTES: usize = 24;
const TAG_BYTES: usize = 16;

const SNAPSHOT_AAD_LABEL: &[u8] = b"bw-cloud-snapshot";
const DATA_KEY_AAD_LABEL: &[u8] = b"bw-cloud-data-key";
const DEVICE_SEAL_LABEL: &[u8] = b"bw-cloud-device-seal";

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CryptoError {
    /// The operating system random source failed.
    Random,
    /// Authentication failed: wrong key, tampered bytes, or mismatched metadata.
    Decrypt,
    /// The envelope is structurally invalid or uses an unknown version or suite.
    InvalidEnvelope(&'static str),
}

impl std::fmt::Display for CryptoError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Random => formatter.write_str("the system random source is unavailable"),
            Self::Decrypt => formatter.write_str("the encrypted data could not be authenticated"),
            Self::InvalidEnvelope(reason) => {
                write!(formatter, "invalid encrypted envelope: {reason}")
            }
        }
    }
}

impl std::error::Error for CryptoError {}

/// A 256-bit secret. Zeroed on drop and deliberately not `Debug`.
#[derive(Clone, Zeroize, ZeroizeOnDrop)]
pub struct SecretKey([u8; KEY_BYTES]);

impl SecretKey {
    pub fn generate() -> Result<Self, CryptoError> {
        let mut bytes = [0u8; KEY_BYTES];
        getrandom::fill(&mut bytes).map_err(|_| CryptoError::Random)?;
        Ok(Self(bytes))
    }

    pub fn from_bytes(bytes: [u8; KEY_BYTES]) -> Self {
        Self(bytes)
    }

    pub fn as_bytes(&self) -> &[u8; KEY_BYTES] {
        &self.0
    }
}

/// An X25519 device identity. The public half is enrolled with the account.
pub struct DeviceKeyPair {
    secret: StaticSecret,
    public: [u8; KEY_BYTES],
}

impl DeviceKeyPair {
    pub fn generate() -> Result<Self, CryptoError> {
        let seed = SecretKey::generate()?;
        let secret = StaticSecret::from(*seed.as_bytes());
        let public = PublicKey::from(&secret).to_bytes();
        Ok(Self { secret, public })
    }

    pub fn public_key(&self) -> [u8; KEY_BYTES] {
        self.public
    }
}

/// Encrypts one portable snapshot under a fresh data key, and wraps that data
/// key under the account vault key. Returns the envelope to upload.
pub fn encrypt_snapshot(
    vault_key: &SecretKey,
    portable_budget_id: Uuid,
    schema_version: i32,
    plaintext: &[u8],
) -> Result<BudgetEnvelope, CryptoError> {
    let data_key = SecretKey::generate()?;
    let nonce = random_nonce()?;
    let aad = snapshot_aad(portable_budget_id, schema_version);
    let ciphertext = aead_encrypt(&data_key, &nonce, plaintext, &aad)?;

    let wrap_nonce = random_nonce()?;
    let wrap_aad = data_key_aad(portable_budget_id);
    let wrapped = aead_encrypt(vault_key, &wrap_nonce, data_key.as_bytes(), &wrap_aad)?;

    Ok(BudgetEnvelope {
        envelope_version: ENVELOPE_VERSION,
        suite: SUITE_ID.to_owned(),
        portable_budget_id,
        schema_version,
        nonce: STANDARD.encode(nonce),
        ciphertext: STANDARD.encode(ciphertext),
        wrapped_data_key: WrappedDataKey {
            nonce: STANDARD.encode(wrap_nonce),
            ciphertext: STANDARD.encode(wrapped),
        },
    })
}

/// Authenticates and decrypts an envelope. The caller must still validate the
/// decoded portable JSON before replacing any local cache.
pub fn decrypt_snapshot(
    vault_key: &SecretKey,
    envelope: &BudgetEnvelope,
) -> Result<Vec<u8>, CryptoError> {
    if envelope.envelope_version != ENVELOPE_VERSION {
        return Err(CryptoError::InvalidEnvelope("unsupported envelope version"));
    }
    if envelope.suite != SUITE_ID {
        return Err(CryptoError::InvalidEnvelope("unsupported suite"));
    }

    let wrap_nonce = decode_nonce(&envelope.wrapped_data_key.nonce)?;
    let wrapped = decode(&envelope.wrapped_data_key.ciphertext)?;
    let data_key_bytes = aead_decrypt(
        vault_key,
        &wrap_nonce,
        &wrapped,
        &data_key_aad(envelope.portable_budget_id),
    )?;
    let data_key_array: [u8; KEY_BYTES] = data_key_bytes
        .as_slice()
        .try_into()
        .map_err(|_| CryptoError::InvalidEnvelope("wrapped data key has the wrong length"))?;
    let data_key = SecretKey::from_bytes(data_key_array);

    let nonce = decode_nonce(&envelope.nonce)?;
    let ciphertext = decode(&envelope.ciphertext)?;
    if ciphertext.len() < TAG_BYTES {
        return Err(CryptoError::InvalidEnvelope(
            "ciphertext is shorter than its tag",
        ));
    }
    let aad = snapshot_aad(envelope.portable_budget_id, envelope.schema_version);
    aead_decrypt(&data_key, &nonce, &ciphertext, &aad)
}

/// Seals a secret to a device's X25519 public key. Output layout:
/// ephemeral public key (32) || nonce (24) || ciphertext with tag.
pub fn seal_to_device(
    recipient_public: &[u8; KEY_BYTES],
    plaintext: &[u8],
) -> Result<Vec<u8>, CryptoError> {
    let ephemeral = DeviceKeyPair::generate()?;
    let shared = ephemeral
        .secret
        .diffie_hellman(&PublicKey::from(*recipient_public));
    let key = device_seal_key(shared.as_bytes(), &ephemeral.public, recipient_public)?;
    let nonce = random_nonce()?;
    let ciphertext = aead_encrypt(&key, &nonce, plaintext, DEVICE_SEAL_LABEL)?;

    let mut sealed = Vec::with_capacity(KEY_BYTES + NONCE_BYTES + ciphertext.len());
    sealed.extend_from_slice(&ephemeral.public);
    sealed.extend_from_slice(&nonce);
    sealed.extend_from_slice(&ciphertext);
    Ok(sealed)
}

/// Opens a value produced by [`seal_to_device`] with the recipient's device key.
pub fn open_from_device(device: &DeviceKeyPair, sealed: &[u8]) -> Result<Vec<u8>, CryptoError> {
    if sealed.len() < KEY_BYTES + NONCE_BYTES + TAG_BYTES {
        return Err(CryptoError::InvalidEnvelope("sealed value is too short"));
    }
    let (ephemeral_bytes, rest) = sealed.split_at(KEY_BYTES);
    let (nonce_bytes, ciphertext) = rest.split_at(NONCE_BYTES);
    let ephemeral_public: [u8; KEY_BYTES] = ephemeral_bytes
        .try_into()
        .map_err(|_| CryptoError::InvalidEnvelope("sealed ephemeral key has the wrong length"))?;
    let shared = device
        .secret
        .diffie_hellman(&PublicKey::from(ephemeral_public));
    let key = device_seal_key(shared.as_bytes(), &ephemeral_public, &device.public)?;
    let nonce: [u8; NONCE_BYTES] = nonce_bytes
        .try_into()
        .map_err(|_| CryptoError::InvalidEnvelope("sealed nonce has the wrong length"))?;
    aead_decrypt(&key, &nonce, ciphertext, DEVICE_SEAL_LABEL)
}

fn device_seal_key(
    shared_secret: &[u8; KEY_BYTES],
    ephemeral_public: &[u8; KEY_BYTES],
    recipient_public: &[u8; KEY_BYTES],
) -> Result<SecretKey, CryptoError> {
    // Bind both public keys into the derived key so the shared secret is tied
    // to this exchange only.
    let mut salt = Vec::with_capacity(KEY_BYTES * 2);
    salt.extend_from_slice(ephemeral_public);
    salt.extend_from_slice(recipient_public);
    let hkdf = Hkdf::<Sha256>::new(Some(&salt), shared_secret);
    let mut okm = [0u8; KEY_BYTES];
    hkdf.expand(DEVICE_SEAL_LABEL, &mut okm)
        .map_err(|_| CryptoError::InvalidEnvelope("key derivation failed"))?;
    Ok(SecretKey::from_bytes(okm))
}

fn snapshot_aad(portable_budget_id: Uuid, schema_version: i32) -> Vec<u8> {
    let mut aad = Vec::with_capacity(64);
    aad.extend_from_slice(SNAPSHOT_AAD_LABEL);
    aad.push(0);
    aad.extend_from_slice(&ENVELOPE_VERSION.to_be_bytes());
    aad.extend_from_slice(SUITE_ID.as_bytes());
    aad.push(0);
    aad.extend_from_slice(portable_budget_id.as_bytes());
    aad.extend_from_slice(&schema_version.to_be_bytes());
    aad
}

fn data_key_aad(portable_budget_id: Uuid) -> Vec<u8> {
    let mut aad = Vec::with_capacity(64);
    aad.extend_from_slice(DATA_KEY_AAD_LABEL);
    aad.push(0);
    aad.extend_from_slice(&ENVELOPE_VERSION.to_be_bytes());
    aad.extend_from_slice(SUITE_ID.as_bytes());
    aad.push(0);
    aad.extend_from_slice(portable_budget_id.as_bytes());
    aad
}

fn random_nonce() -> Result<[u8; NONCE_BYTES], CryptoError> {
    let mut nonce = [0u8; NONCE_BYTES];
    getrandom::fill(&mut nonce).map_err(|_| CryptoError::Random)?;
    Ok(nonce)
}

fn aead_encrypt(
    key: &SecretKey,
    nonce: &[u8; NONCE_BYTES],
    plaintext: &[u8],
    aad: &[u8],
) -> Result<Vec<u8>, CryptoError> {
    let cipher = XChaCha20Poly1305::new(key.as_bytes().into());
    cipher
        .encrypt(
            &XNonce::from(*nonce),
            Payload {
                msg: plaintext,
                aad,
            },
        )
        .map_err(|_| CryptoError::Decrypt)
}

fn aead_decrypt(
    key: &SecretKey,
    nonce: &[u8; NONCE_BYTES],
    ciphertext: &[u8],
    aad: &[u8],
) -> Result<Vec<u8>, CryptoError> {
    let cipher = XChaCha20Poly1305::new(key.as_bytes().into());
    cipher
        .decrypt(
            &XNonce::from(*nonce),
            Payload {
                msg: ciphertext,
                aad,
            },
        )
        .map_err(|_| CryptoError::Decrypt)
}

fn decode(value: &str) -> Result<Vec<u8>, CryptoError> {
    STANDARD
        .decode(value)
        .map_err(|_| CryptoError::InvalidEnvelope("field is not standard base64"))
}

fn decode_nonce(value: &str) -> Result<[u8; NONCE_BYTES], CryptoError> {
    decode(value)?
        .try_into()
        .map_err(|_| CryptoError::InvalidEnvelope("nonce must be 24 bytes"))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn budget_id() -> Uuid {
        Uuid::parse_str("3f2a9c1e-5b7d-4e8a-9c21-7d4e5f6a8b90").unwrap()
    }

    #[test]
    fn snapshot_round_trips_under_the_vault_key() {
        let vault = SecretKey::generate().unwrap();
        let plaintext = br#"{"id":"3f2a9c1e-5b7d-4e8a-9c21-7d4e5f6a8b90","title":"Home"}"#;
        let envelope = encrypt_snapshot(&vault, budget_id(), 2, plaintext).unwrap();

        assert_eq!(envelope.suite, SUITE_ID);
        assert!(!STANDARD.decode(&envelope.ciphertext).unwrap().is_empty());
        assert_eq!(decrypt_snapshot(&vault, &envelope).unwrap(), plaintext);
    }

    #[test]
    fn two_encryptions_of_the_same_plaintext_differ() {
        let vault = SecretKey::generate().unwrap();
        let first = encrypt_snapshot(&vault, budget_id(), 2, b"same").unwrap();
        let second = encrypt_snapshot(&vault, budget_id(), 2, b"same").unwrap();
        assert_ne!(first.nonce, second.nonce);
        assert_ne!(first.ciphertext, second.ciphertext);
    }

    #[test]
    fn wrong_vault_key_fails_authentication() {
        let vault = SecretKey::generate().unwrap();
        let other = SecretKey::generate().unwrap();
        let envelope = encrypt_snapshot(&vault, budget_id(), 2, b"secret").unwrap();
        assert_eq!(
            decrypt_snapshot(&other, &envelope),
            Err(CryptoError::Decrypt)
        );
    }

    #[test]
    fn tampered_ciphertext_fails_authentication() {
        let vault = SecretKey::generate().unwrap();
        let mut envelope = encrypt_snapshot(&vault, budget_id(), 2, b"secret").unwrap();
        let mut bytes = STANDARD.decode(&envelope.ciphertext).unwrap();
        bytes[0] ^= 0x01;
        envelope.ciphertext = STANDARD.encode(bytes);
        assert_eq!(
            decrypt_snapshot(&vault, &envelope),
            Err(CryptoError::Decrypt)
        );
    }

    #[test]
    fn changed_routing_metadata_fails_authentication() {
        let vault = SecretKey::generate().unwrap();
        let envelope = encrypt_snapshot(&vault, budget_id(), 2, b"secret").unwrap();

        let mut other_budget = envelope.clone();
        other_budget.portable_budget_id = Uuid::new_v4();
        assert_eq!(
            decrypt_snapshot(&vault, &other_budget),
            Err(CryptoError::Decrypt)
        );

        let mut other_schema = envelope.clone();
        other_schema.schema_version = 3;
        assert_eq!(
            decrypt_snapshot(&vault, &other_schema),
            Err(CryptoError::Decrypt)
        );
    }

    #[test]
    fn unknown_suite_and_version_are_rejected_before_decrypting() {
        let vault = SecretKey::generate().unwrap();
        let envelope = encrypt_snapshot(&vault, budget_id(), 2, b"secret").unwrap();

        let mut suite = envelope.clone();
        suite.suite = "plaintext".to_owned();
        assert!(matches!(
            decrypt_snapshot(&vault, &suite),
            Err(CryptoError::InvalidEnvelope(_))
        ));

        let mut version = envelope;
        version.envelope_version = 2;
        assert!(matches!(
            decrypt_snapshot(&vault, &version),
            Err(CryptoError::InvalidEnvelope(_))
        ));
    }

    #[test]
    fn wrapped_data_key_is_bound_to_its_budget() {
        let vault = SecretKey::generate().unwrap();
        let envelope = encrypt_snapshot(&vault, budget_id(), 2, b"secret").unwrap();
        let mut moved = envelope.clone();
        moved.portable_budget_id = Uuid::new_v4();
        assert_eq!(decrypt_snapshot(&vault, &moved), Err(CryptoError::Decrypt));
    }

    #[test]
    fn device_seal_round_trips_and_rejects_other_devices() {
        let device = DeviceKeyPair::generate().unwrap();
        let other = DeviceKeyPair::generate().unwrap();
        let vault = SecretKey::generate().unwrap();

        let sealed = seal_to_device(&device.public_key(), vault.as_bytes()).unwrap();
        assert_eq!(
            open_from_device(&device, &sealed).unwrap(),
            vault.as_bytes()
        );
        assert_eq!(open_from_device(&other, &sealed), Err(CryptoError::Decrypt));
    }

    #[test]
    fn device_seal_detects_tampering() {
        let device = DeviceKeyPair::generate().unwrap();
        let mut sealed = seal_to_device(&device.public_key(), b"vault").unwrap();
        let last = sealed.len() - 1;
        sealed[last] ^= 0x80;
        assert_eq!(
            open_from_device(&device, &sealed),
            Err(CryptoError::Decrypt)
        );
    }

    #[test]
    fn short_sealed_values_are_rejected() {
        let device = DeviceKeyPair::generate().unwrap();
        assert!(matches!(
            open_from_device(&device, &[0u8; 10]),
            Err(CryptoError::InvalidEnvelope(_))
        ));
    }
}
