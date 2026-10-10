use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use hmac::{Hmac, Mac};
use serde::{Serialize, de::DeserializeOwned};
use sha2::{Digest, Sha256};

type HmacSha256 = Hmac<Sha256>;

pub fn sign<T: Serialize>(secret: &[u8], value: &T) -> Result<String, serde_json::Error> {
    let payload = serde_json::to_vec(value)?;
    let encoded = URL_SAFE_NO_PAD.encode(payload);
    let mut mac = HmacSha256::new_from_slice(secret).expect("HMAC accepts every key size");
    mac.update(encoded.as_bytes());
    let signature = URL_SAFE_NO_PAD.encode(mac.finalize().into_bytes());
    Ok(format!("{encoded}.{signature}"))
}

pub fn verify<T: DeserializeOwned>(secret: &[u8], token: &str) -> Result<T, TokenError> {
    let (payload, signature) = token.split_once('.').ok_or(TokenError)?;
    if signature.contains('.') {
        return Err(TokenError);
    }
    let signature = URL_SAFE_NO_PAD.decode(signature).map_err(|_| TokenError)?;
    let mut mac = HmacSha256::new_from_slice(secret).expect("HMAC accepts every key size");
    mac.update(payload.as_bytes());
    mac.verify_slice(&signature).map_err(|_| TokenError)?;
    let payload = URL_SAFE_NO_PAD.decode(payload).map_err(|_| TokenError)?;
    serde_json::from_slice(&payload).map_err(|_| TokenError)
}

#[derive(Clone, Copy, Debug)]
pub struct TokenError;

pub fn digest(bytes: &[u8]) -> [u8; 32] {
    Sha256::digest(bytes).into()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn signed_tokens_reject_tampering_and_wrong_keys() {
        let token = sign(
            b"secret",
            &serde_json::json!({"account": "one", "sequence": 42}),
        )
        .unwrap();
        let decoded: serde_json::Value = verify(b"secret", &token).unwrap();
        assert_eq!(decoded["sequence"], 42);
        assert!(verify::<serde_json::Value>(b"other", &token).is_err());
        let mut tampered = token.into_bytes();
        tampered[0] = if tampered[0] == b'A' { b'B' } else { b'A' };
        assert!(
            verify::<serde_json::Value>(b"secret", std::str::from_utf8(&tampered).unwrap())
                .is_err()
        );
        for malformed in ["", "abc", "abc.def.extra", "abc.!", "!.abc"] {
            assert!(verify::<serde_json::Value>(b"secret", malformed).is_err());
        }
    }
}
