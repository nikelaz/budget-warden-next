//! App Store (StoreKit 2) adapter.
//!
//! Signed transactions and renewal info are JWS tokens whose `x5c` header
//! carries a certificate chain. The chain must end at the pinned Apple Root CA
//! G3 before any claim is trusted. Account correlation uses the
//! `appAccountToken`, which the client sets to the Budget Warden account ID.

use aws_lc_rs::signature::{ECDSA_P256_SHA256_ASN1, ECDSA_P256_SHA256_FIXED, UnparsedPublicKey};
use base64::{
    Engine as _,
    engine::general_purpose::{STANDARD, URL_SAFE_NO_PAD},
};
use chrono::{DateTime, TimeZone, Utc};
use jsonwebtoken::{Algorithm, EncodingKey, Header, encode};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use uuid::Uuid;
use x509_parser::prelude::{ASN1Time, FromDer, X509Certificate};

use super::{BillingClients, Provider, SubState, SubscriptionUpdate, provider_unavailable};
use crate::{config::StoreKitConfig, errors::ApiResult};

/// Apple Root CA - G3, SHA-256 fingerprint 63:34:3A:BF:…:79. Loaded from the
/// bundled DER file so verification never depends on the network.
pub const APPLE_ROOT_CA_G3_DER: &[u8] = include_bytes!("apple_root_g3.cer");

const ECDSA_SHA256_OID: &str = "1.2.840.10045.4.3.2";
const EC_PUBLIC_KEY_OID: &str = "1.2.840.10045.2.1";
pub const MANAGEMENT_URL: &str = "https://apps.apple.com/account/subscriptions";

#[derive(Debug, PartialEq, Eq)]
pub enum AppleError {
    Malformed(&'static str),
    UntrustedChain,
    BadSignature,
    Expired,
}

fn decode_b64url(part: &str) -> Result<Vec<u8>, AppleError> {
    URL_SAFE_NO_PAD
        .decode(part)
        .map_err(|_| AppleError::Malformed("segment is not base64url"))
}

/// Verifies a StoreKit JWS and returns its payload as JSON.
pub fn verify_signed_payload(
    token: &str,
    trusted_root_der: &[u8],
    now: DateTime<Utc>,
) -> Result<Value, AppleError> {
    let parts: Vec<&str> = token.split('.').collect();
    let [header_part, payload_part, signature_part] = parts.as_slice() else {
        return Err(AppleError::Malformed("token must have three segments"));
    };
    let header: Value = serde_json::from_slice(&decode_b64url(header_part)?)
        .map_err(|_| AppleError::Malformed("header is not JSON"))?;
    if header.get("alg").and_then(Value::as_str) != Some("ES256") {
        return Err(AppleError::Malformed("algorithm must be ES256"));
    }
    let chain = header
        .get("x5c")
        .and_then(Value::as_array)
        .filter(|chain| !chain.is_empty())
        .ok_or(AppleError::Malformed("x5c chain is missing"))?;
    let chain_der: Vec<Vec<u8>> = chain
        .iter()
        .map(|item| {
            item.as_str()
                .and_then(|text| STANDARD.decode(text).ok())
                .ok_or(AppleError::Malformed("x5c entry is not base64"))
        })
        .collect::<Result<_, _>>()?;

    verify_chain(&chain_der, trusted_root_der, now)?;

    let leaf_der = &chain_der[0];
    let (_, leaf) = X509Certificate::from_der(leaf_der)
        .map_err(|_| AppleError::Malformed("leaf certificate is not DER"))?;
    let public_point = leaf.public_key().subject_public_key.data.to_vec();
    let signed = format!("{header_part}.{payload_part}");
    let signature = decode_b64url(signature_part)?;
    UnparsedPublicKey::new(&ECDSA_P256_SHA256_FIXED, &public_point)
        .verify(signed.as_bytes(), &signature)
        .map_err(|_| AppleError::BadSignature)?;

    serde_json::from_slice(&decode_b64url(payload_part)?)
        .map_err(|_| AppleError::Malformed("payload is not JSON"))
}

/// Checks that each certificate is valid now and signed by the next one, and
/// that the chain reaches `trusted_root_der`.
fn verify_chain(
    chain: &[Vec<u8>],
    trusted_root_der: &[u8],
    now: DateTime<Utc>,
) -> Result<(), AppleError> {
    let now = ASN1Time::from_timestamp(now.timestamp()).map_err(|_| AppleError::Expired)?;
    let parsed: Vec<X509Certificate> = chain
        .iter()
        .map(|der| {
            X509Certificate::from_der(der)
                .map(|(_, cert)| cert)
                .map_err(|_| AppleError::Malformed("certificate is not DER"))
        })
        .collect::<Result<_, _>>()?;
    let (_, root) =
        X509Certificate::from_der(trusted_root_der).map_err(|_| AppleError::UntrustedChain)?;

    for (index, cert) in parsed.iter().enumerate() {
        if !cert.validity().is_valid_at(now) {
            return Err(AppleError::Expired);
        }
        if chain[index].as_slice() == trusted_root_der {
            return Ok(());
        }
        let issuer = match parsed.get(index + 1) {
            Some(next) => next,
            None => &root,
        };
        verify_certificate_signature(cert, issuer)?;
    }
    // The last certificate was verified by the pinned root.
    Ok(())
}

fn verify_certificate_signature(
    cert: &X509Certificate,
    issuer: &X509Certificate,
) -> Result<(), AppleError> {
    if cert.signature_algorithm.algorithm.to_id_string() != ECDSA_SHA256_OID
        || issuer.public_key().algorithm.algorithm.to_id_string() != EC_PUBLIC_KEY_OID
    {
        return Err(AppleError::UntrustedChain);
    }
    let issuer_point = issuer.public_key().subject_public_key.data.to_vec();
    UnparsedPublicKey::new(&ECDSA_P256_SHA256_ASN1, &issuer_point)
        .verify(cert.tbs_certificate.as_ref(), &cert.signature_value.data)
        .map_err(|_| AppleError::UntrustedChain)
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TransactionInfo {
    pub original_transaction_id: String,
    pub app_account_token: Option<String>,
    pub bundle_id: Option<String>,
    pub expires_date: Option<i64>,
    pub revocation_date: Option<i64>,
    pub signed_date: Option<i64>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RenewalInfo {
    pub auto_renew_status: Option<i32>,
    pub is_in_billing_retry_period: Option<bool>,
    pub grace_period_expires_date: Option<i64>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct NotificationPayload {
    pub notification_type: String,
    pub notification_uuid: String,
    pub data: Option<NotificationData>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct NotificationData {
    pub bundle_id: Option<String>,
    pub signed_transaction_info: Option<String>,
    pub signed_renewal_info: Option<String>,
}

fn millis(value: i64) -> Option<DateTime<Utc>> {
    Utc.timestamp_millis_opt(value).single()
}

/// Maps a verified transaction and its optional renewal info to an update.
pub fn update_from_transaction(
    transaction: &TransactionInfo,
    renewal: Option<&RenewalInfo>,
    observed_at: DateTime<Utc>,
) -> SubscriptionUpdate {
    let now = observed_at;
    let expires = transaction.expires_date.and_then(millis);
    let revoked = transaction.revocation_date.and_then(millis);
    let grace_until = renewal
        .and_then(|renewal| renewal.grace_period_expires_date)
        .and_then(millis);
    let in_retry = renewal.is_some_and(|renewal| renewal.is_in_billing_retry_period == Some(true));
    let auto_renews = renewal.is_some_and(|renewal| renewal.auto_renew_status == Some(1));

    let (state, access_until, status) = if let Some(revoked_at) = revoked {
        (SubState::Revoked, Some(revoked_at), "revoked")
    } else if let Some(expires_at) = expires.filter(|expires_at| *expires_at > now) {
        if in_retry {
            (SubState::PaymentRetry, Some(expires_at), "billing_retry")
        } else {
            (SubState::Active, Some(expires_at), "active")
        }
    } else if let Some(grace) = grace_until.filter(|grace| *grace > now) {
        (SubState::Grace, Some(grace), "grace_period")
    } else {
        (SubState::Expired, expires, "expired")
    };

    SubscriptionUpdate {
        provider: Provider::Apple,
        provider_subscription_id: transaction.original_transaction_id.clone(),
        account_id: transaction
            .app_account_token
            .as_deref()
            .and_then(|token| Uuid::parse_str(token).ok()),
        state,
        access_until,
        auto_renews: auto_renews && state != SubState::Revoked,
        management_url: Some(MANAGEMENT_URL.to_owned()),
        provider_status: status.to_owned(),
        provider_updated_at: transaction.signed_date.and_then(millis).unwrap_or(now),
    }
}

/// Verifies a notification's signed data and returns its transaction and
/// renewal claims. Returns `Ok(None)` for test notifications.
pub fn decode_notification(
    payload: &NotificationPayload,
    trusted_root_der: &[u8],
    now: DateTime<Utc>,
) -> Result<Option<(TransactionInfo, Option<RenewalInfo>)>, AppleError> {
    let Some(data) = payload.data.as_ref() else {
        return Ok(None);
    };
    let Some(transaction_jws) = data.signed_transaction_info.as_deref() else {
        return Ok(None);
    };
    let transaction: TransactionInfo = serde_json::from_value(verify_signed_payload(
        transaction_jws,
        trusted_root_der,
        now,
    )?)
    .map_err(|_| AppleError::Malformed("transaction claims do not match"))?;
    let renewal = match data.signed_renewal_info.as_deref() {
        Some(jws) => Some(
            serde_json::from_value(verify_signed_payload(jws, trusted_root_der, now)?)
                .map_err(|_| AppleError::Malformed("renewal claims do not match"))?,
        ),
        None => None,
    };
    Ok(Some((transaction, renewal)))
}

/// Parses an App Store Server Notification V2 signed payload.
pub fn parse_notification(
    signed_payload: &str,
    trusted_root_der: &[u8],
    now: DateTime<Utc>,
) -> Result<NotificationPayload, AppleError> {
    serde_json::from_value(verify_signed_payload(
        signed_payload,
        trusted_root_der,
        now,
    )?)
    .map_err(|_| AppleError::Malformed("notification claims do not match"))
}

#[derive(Serialize)]
struct StoreKitClaims<'a> {
    iss: &'a str,
    iat: i64,
    exp: i64,
    aud: &'static str,
    bid: &'a str,
}

/// Creates the short-lived ES256 token used for App Store Server API calls.
pub fn api_token(config: &StoreKitConfig, now: DateTime<Utc>) -> ApiResult<String> {
    let (Some(issuer), Some(bundle), Some(key_id), Some(private_key)) = (
        config.issuer_id.as_deref(),
        config.bundle_id.as_deref(),
        config.key_id.as_deref(),
        config.private_key.as_deref(),
    ) else {
        return Err(provider_unavailable("StoreKit API is not configured."));
    };
    let key = EncodingKey::from_ec_pem(private_key.as_bytes())
        .map_err(|_| provider_unavailable("StoreKit private key is invalid."))?;
    let mut header = Header::new(Algorithm::ES256);
    header.kid = Some(key_id.to_owned());
    header.typ = Some("JWT".to_owned());
    let claims = StoreKitClaims {
        iss: issuer,
        iat: now.timestamp(),
        exp: now.timestamp() + 300,
        aud: "appstoreconnect-v1",
        bid: bundle,
    };
    encode(&header, &claims, &key).map_err(|_| provider_unavailable("StoreKit token failed."))
}

fn api_base(sandbox: bool) -> &'static str {
    if sandbox {
        "https://api.storekit-sandbox.itunes.apple.com"
    } else {
        "https://api.storekit.itunes.apple.com"
    }
}

/// Returns the latest signed transaction and renewal JWS for an original
/// transaction ID.
pub async fn fetch_latest_signed(
    clients: &BillingClients,
    config: &StoreKitConfig,
    original_transaction_id: &str,
    now: DateTime<Utc>,
) -> ApiResult<Option<(String, Option<String>)>> {
    let token = api_token(config, now)?;
    let response = clients
        .http
        .get(format!(
            "{}/inApps/v1/subscriptions/{original_transaction_id}",
            api_base(config.sandbox)
        ))
        .bearer_auth(token)
        .send()
        .await
        .map_err(|_| provider_unavailable("The App Store could not be reached."))?;
    if response.status().as_u16() == 404 {
        return Ok(None);
    }
    if !response.status().is_success() {
        return Err(provider_unavailable(
            "The App Store did not return the subscription.",
        ));
    }
    let body: Value = response
        .json()
        .await
        .map_err(|_| provider_unavailable("The App Store returned an unreadable response."))?;
    let latest = body
        .get("data")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .flat_map(|group| {
            group
                .get("lastTransactions")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
        })
        .find(|item| {
            item.get("originalTransactionId").and_then(Value::as_str)
                == Some(original_transaction_id)
        });
    Ok(latest.and_then(|item| {
        let transaction = item.get("signedTransactionInfo")?.as_str()?.to_owned();
        let renewal = item
            .get("signedRenewalInfo")
            .and_then(Value::as_str)
            .map(str::to_owned);
        Some((transaction, renewal))
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn now() -> DateTime<Utc> {
        Utc.with_ymd_and_hms(2026, 3, 1, 12, 0, 0).unwrap()
    }

    fn transaction(expires_ms: i64, revocation: Option<i64>) -> TransactionInfo {
        TransactionInfo {
            original_transaction_id: "2000000000001".to_owned(),
            app_account_token: Some("3f2a9c1e-5b7d-4e8a-9c21-7d4e5f6a8b90".to_owned()),
            bundle_id: Some("com.lazarovco.budgetwarden".to_owned()),
            expires_date: Some(expires_ms),
            revocation_date: revocation,
            signed_date: Some(now().timestamp_millis()),
        }
    }

    fn renewal(auto: i32, retry: bool, grace_ms: Option<i64>) -> RenewalInfo {
        RenewalInfo {
            auto_renew_status: Some(auto),
            is_in_billing_retry_period: Some(retry),
            grace_period_expires_date: grace_ms,
        }
    }

    #[test]
    fn current_auto_renewing_transaction_is_active() {
        let expires = (now() + chrono::Duration::days(20)).timestamp_millis();
        let update = update_from_transaction(
            &transaction(expires, None),
            Some(&renewal(1, false, None)),
            now(),
        );
        assert_eq!(update.state, SubState::Active);
        assert!(update.auto_renews);
        assert_eq!(
            update.account_id,
            Some(Uuid::parse_str("3f2a9c1e-5b7d-4e8a-9c21-7d4e5f6a8b90").unwrap())
        );
    }

    #[test]
    fn billing_retry_keeps_access_until_expiry_only() {
        let expires = (now() + chrono::Duration::days(3)).timestamp_millis();
        let update = update_from_transaction(
            &transaction(expires, None),
            Some(&renewal(1, true, None)),
            now(),
        );
        assert_eq!(update.state, SubState::PaymentRetry);
        assert_eq!(update.access_until, millis(expires));
    }

    #[test]
    fn grace_period_extends_access_after_expiry() {
        let expires = (now() - chrono::Duration::days(1)).timestamp_millis();
        let grace = (now() + chrono::Duration::days(5)).timestamp_millis();
        let update = update_from_transaction(
            &transaction(expires, None),
            Some(&renewal(1, true, Some(grace))),
            now(),
        );
        assert_eq!(update.state, SubState::Grace);
        assert_eq!(update.access_until, millis(grace));
    }

    #[test]
    fn revocation_ends_access_immediately() {
        let expires = (now() + chrono::Duration::days(20)).timestamp_millis();
        let revoked = (now() - chrono::Duration::hours(1)).timestamp_millis();
        let update = update_from_transaction(&transaction(expires, Some(revoked)), None, now());
        assert_eq!(update.state, SubState::Revoked);
        assert!(!update.auto_renews);
    }

    #[test]
    fn turned_off_auto_renew_is_not_renewing() {
        let expires = (now() + chrono::Duration::days(20)).timestamp_millis();
        let update = update_from_transaction(
            &transaction(expires, None),
            Some(&renewal(0, false, None)),
            now(),
        );
        assert_eq!(update.state, SubState::Active);
        assert!(!update.auto_renews);
    }

    #[test]
    fn rejects_jws_without_a_certificate_chain() {
        let header = URL_SAFE_NO_PAD.encode(br#"{"alg":"ES256"}"#);
        let payload = URL_SAFE_NO_PAD.encode(br#"{}"#);
        let token = format!("{header}.{payload}.AAAA");
        assert_eq!(
            verify_signed_payload(&token, APPLE_ROOT_CA_G3_DER, now()),
            Err(AppleError::Malformed("x5c chain is missing"))
        );
    }

    #[test]
    fn rejects_non_es256_algorithms() {
        let header = URL_SAFE_NO_PAD.encode(br#"{"alg":"none","x5c":["AAAA"]}"#);
        let token = format!("{header}.e30.AAAA");
        assert_eq!(
            verify_signed_payload(&token, APPLE_ROOT_CA_G3_DER, now()),
            Err(AppleError::Malformed("algorithm must be ES256"))
        );
    }

    #[test]
    fn bundled_root_is_the_pinned_apple_root_ca_g3() {
        let (_, root) = X509Certificate::from_der(APPLE_ROOT_CA_G3_DER).unwrap();
        assert!(root.subject().to_string().contains("Apple Root CA - G3"));
        assert_eq!(root.subject().to_string(), root.issuer().to_string());
    }
}

#[cfg(test)]
mod chain_tests {
    use super::*;

    /// Chain generated by `src/billing/testdata/generate.sh`: test root,
    /// intermediate, and leaf, with one JWS signed by the leaf.
    const TEST_ROOT_DER: &[u8] = include_bytes!("testdata/root.der");
    const SIGNED_TRANSACTION: &str = include_str!("testdata/signed_transaction.jws");

    fn now() -> DateTime<Utc> {
        Utc::now()
    }

    #[test]
    fn verifies_a_jws_whose_chain_ends_at_the_trusted_root() {
        let claims =
            verify_signed_payload(SIGNED_TRANSACTION.trim(), TEST_ROOT_DER, now()).unwrap();
        assert_eq!(claims["originalTransactionId"], "2000000000001");
        assert_eq!(claims["bundleId"], "com.lazarovco.budgetwarden");
    }

    #[test]
    fn rejects_a_chain_that_does_not_end_at_the_pinned_apple_root() {
        assert_eq!(
            verify_signed_payload(SIGNED_TRANSACTION.trim(), APPLE_ROOT_CA_G3_DER, now()),
            Err(AppleError::UntrustedChain)
        );
    }

    #[test]
    fn rejects_a_tampered_payload() {
        let token = SIGNED_TRANSACTION.trim();
        let parts: Vec<&str> = token.split('.').collect();
        let mut claims: Value =
            serde_json::from_slice(&URL_SAFE_NO_PAD.decode(parts[1]).unwrap()).unwrap();
        claims["bundleId"] = Value::String("com.attacker.app".to_owned());
        let forged_payload = URL_SAFE_NO_PAD.encode(serde_json::to_vec(&claims).unwrap());
        let forged = format!("{}.{}.{}", parts[0], forged_payload, parts[2]);
        assert_eq!(
            verify_signed_payload(&forged, TEST_ROOT_DER, now()),
            Err(AppleError::BadSignature)
        );
    }

    #[test]
    fn rejects_a_tampered_signature() {
        let token = SIGNED_TRANSACTION.trim();
        let mut bytes = token.as_bytes().to_vec();
        let last = bytes.len() - 1;
        bytes[last] = if bytes[last] == b'A' { b'B' } else { b'A' };
        let forged = String::from_utf8(bytes).unwrap();
        assert!(verify_signed_payload(&forged, TEST_ROOT_DER, now()).is_err());
    }
}
