//! Google Play adapter.
//!
//! Purchases are read from the Play Developer API using a service account;
//! the developer API is the source of truth, so notifications only say *which*
//! purchase changed. The client binds purchases to accounts by setting
//! `obfuscatedAccountId` to the Budget Warden account ID.

use chrono::{DateTime, Utc};
use jsonwebtoken::{Algorithm, EncodingKey, Header, encode};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use uuid::Uuid;

use super::{
    BillingClients, CachedToken, Provider, SubState, SubscriptionUpdate, provider_unavailable,
};
use crate::{config::GooglePlayConfig, errors::ApiResult};

const PLAY_SCOPE: &str = "https://www.googleapis.com/auth/androidpublisher";
const TOKEN_URL: &str = "https://oauth2.googleapis.com/token";
pub const MANAGEMENT_URL: &str = "https://play.google.com/store/account/subscriptions";

#[derive(Serialize)]
struct AssertionClaims<'a> {
    iss: &'a str,
    scope: &'static str,
    aud: &'static str,
    iat: i64,
    exp: i64,
}

#[derive(Deserialize)]
struct TokenResponse {
    access_token: String,
    expires_in: u64,
}

/// Returns a Play API access token, minted from the service account and cached
/// until shortly before it expires.
pub async fn access_token(
    clients: &BillingClients,
    config: &GooglePlayConfig,
    now: DateTime<Utc>,
) -> ApiResult<String> {
    let mut cached = clients.google_token.lock().await;
    if let Some(token) = cached.as_ref()
        && token.expires_at > std::time::Instant::now()
    {
        return Ok(token.value.clone());
    }
    let (Some(email), Some(private_key)) = (
        config.service_account_email.as_deref(),
        config.private_key.as_deref(),
    ) else {
        return Err(provider_unavailable("Google Play is not configured."));
    };
    let key = EncodingKey::from_rsa_pem(private_key.as_bytes())
        .map_err(|_| provider_unavailable("Google Play private key is invalid."))?;
    let claims = AssertionClaims {
        iss: email,
        scope: PLAY_SCOPE,
        aud: TOKEN_URL,
        iat: now.timestamp(),
        exp: now.timestamp() + 3600,
    };
    let assertion = encode(&Header::new(Algorithm::RS256), &claims, &key)
        .map_err(|_| provider_unavailable("Google Play assertion failed."))?;
    let response = clients
        .http
        .post(TOKEN_URL)
        .form(&[
            ("grant_type", "urn:ietf:params:oauth:grant-type:jwt-bearer"),
            ("assertion", assertion.as_str()),
        ])
        .send()
        .await
        .map_err(|_| provider_unavailable("Google token service could not be reached."))?;
    if !response.status().is_success() {
        return Err(provider_unavailable(
            "Google token service rejected the assertion.",
        ));
    }
    let token: TokenResponse = response
        .json()
        .await
        .map_err(|_| provider_unavailable("Google token response was unreadable."))?;
    let lifetime = std::time::Duration::from_secs(token.expires_in.saturating_sub(120));
    *cached = Some(CachedToken {
        value: token.access_token.clone(),
        expires_at: std::time::Instant::now() + lifetime,
    });
    Ok(token.access_token)
}

/// The fields of a SubscriptionPurchaseV2 this service uses.
#[derive(Debug, Clone)]
pub struct PlayPurchase {
    pub subscription_state: String,
    pub expiry: Option<DateTime<Utc>>,
    pub auto_renewing: bool,
    pub obfuscated_account_id: Option<String>,
}

/// Fetches a purchase from the Play Developer API. `Ok(None)` means Google
/// does not know the token.
pub async fn fetch_purchase(
    clients: &BillingClients,
    config: &GooglePlayConfig,
    purchase_token: &str,
    now: DateTime<Utc>,
) -> ApiResult<Option<PlayPurchase>> {
    let Some(package) = config.package_name.as_deref() else {
        return Err(provider_unavailable("Google Play is not configured."));
    };
    let token = access_token(clients, config, now).await?;
    let response = clients
        .http
        .get(format!(
            "https://androidpublisher.googleapis.com/androidpublisher/v3/applications/{package}/purchases/subscriptionsv2/tokens/{purchase_token}"
        ))
        .bearer_auth(token)
        .send()
        .await
        .map_err(|_| provider_unavailable("Google Play could not be reached."))?;
    if response.status().as_u16() == 404 {
        return Ok(None);
    }
    if !response.status().is_success() {
        return Err(provider_unavailable(
            "Google Play did not return the purchase.",
        ));
    }
    let body: Value = response
        .json()
        .await
        .map_err(|_| provider_unavailable("Google Play returned an unreadable purchase."))?;
    Ok(Some(parse_purchase(&body)))
}

pub fn parse_purchase(body: &Value) -> PlayPurchase {
    let line_item = body
        .get("lineItems")
        .and_then(Value::as_array)
        .and_then(|items| items.first());
    PlayPurchase {
        subscription_state: body
            .get("subscriptionState")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_owned(),
        expiry: line_item
            .and_then(|item| item.get("expiryTime"))
            .and_then(Value::as_str)
            .and_then(|text| DateTime::parse_from_rfc3339(text).ok())
            .map(|time| time.with_timezone(&Utc)),
        auto_renewing: line_item
            .and_then(|item| item.get("autoRenewingPlan"))
            .is_some(),
        obfuscated_account_id: body
            .pointer("/externalAccountIdentifiers/obfuscatedExternalAccountId")
            .and_then(Value::as_str)
            .map(str::to_owned),
    }
}

/// Maps a purchase to an update. Returns `None` for states this service does
/// not track.
pub fn update_from_purchase(
    purchase_token: &str,
    purchase: &PlayPurchase,
    observed_at: DateTime<Utc>,
) -> Option<SubscriptionUpdate> {
    let account_id = purchase
        .obfuscated_account_id
        .as_deref()
        .and_then(|value| Uuid::parse_str(value).ok());
    let (state, access_until, auto_renews) = match purchase.subscription_state.as_str() {
        "SUBSCRIPTION_STATE_ACTIVE" => (SubState::Active, purchase.expiry, purchase.auto_renewing),
        "SUBSCRIPTION_STATE_IN_GRACE_PERIOD" => {
            (SubState::Grace, purchase.expiry, purchase.auto_renewing)
        }
        "SUBSCRIPTION_STATE_ON_HOLD" => (SubState::PaymentRetry, purchase.expiry, true),
        // Canceled purchases stay usable until their expiry time.
        "SUBSCRIPTION_STATE_CANCELED" => (SubState::Active, purchase.expiry, false),
        "SUBSCRIPTION_STATE_PAUSED" => (SubState::Paused, None, false),
        "SUBSCRIPTION_STATE_EXPIRED" => (SubState::Expired, purchase.expiry, false),
        "SUBSCRIPTION_STATE_PENDING" => (SubState::Pending, None, false),
        "SUBSCRIPTION_STATE_PENDING_PURCHASE_CANCELED" => (SubState::Expired, None, false),
        _ => return None,
    };
    Some(SubscriptionUpdate {
        provider: Provider::Google,
        provider_subscription_id: purchase_token.to_owned(),
        account_id,
        state,
        access_until,
        auto_renews,
        management_url: Some(MANAGEMENT_URL.to_owned()),
        provider_status: purchase.subscription_state.clone(),
        provider_updated_at: observed_at,
    })
}

/// The Pub/Sub developer notification envelope. Only the purchase token and
/// package are used; the state comes from the Play API.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DeveloperNotification {
    pub package_name: Option<String>,
    pub subscription_notification: Option<SubscriptionNotification>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SubscriptionNotification {
    pub notification_type: i32,
    pub purchase_token: String,
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone;
    use serde_json::json;

    fn now() -> DateTime<Utc> {
        Utc.with_ymd_and_hms(2026, 3, 1, 12, 0, 0).unwrap()
    }

    fn purchase(state: &str, auto: bool) -> Value {
        let mut line = json!({
            "productId": "cloud.monthly",
            "expiryTime": "2026-04-01T00:00:00Z"
        });
        if auto {
            line["autoRenewingPlan"] = json!({ "autoRenewEnabled": true });
        }
        json!({
            "subscriptionState": state,
            "lineItems": [line],
            "externalAccountIdentifiers": {
                "obfuscatedExternalAccountId": "3f2a9c1e-5b7d-4e8a-9c21-7d4e5f6a8b90"
            }
        })
    }

    #[test]
    fn active_auto_renewing_purchase_maps_to_active() {
        let parsed = parse_purchase(&purchase("SUBSCRIPTION_STATE_ACTIVE", true));
        let update = update_from_purchase("tok", &parsed, now()).unwrap();
        assert_eq!(update.state, SubState::Active);
        assert!(update.auto_renews);
        assert_eq!(
            update.account_id,
            Some(Uuid::parse_str("3f2a9c1e-5b7d-4e8a-9c21-7d4e5f6a8b90").unwrap())
        );
    }

    #[test]
    fn canceled_purchase_keeps_access_until_expiry() {
        let parsed = parse_purchase(&purchase("SUBSCRIPTION_STATE_CANCELED", false));
        let update = update_from_purchase("tok", &parsed, now()).unwrap();
        assert_eq!(update.state, SubState::Active);
        assert!(!update.auto_renews);
        assert_eq!(update.access_until, parsed.expiry);
    }

    #[test]
    fn on_hold_keeps_access_only_until_expiry() {
        let parsed = parse_purchase(&purchase("SUBSCRIPTION_STATE_ON_HOLD", true));
        let update = update_from_purchase("tok", &parsed, now()).unwrap();
        assert_eq!(update.state, SubState::PaymentRetry);
        assert_eq!(update.access_until, parsed.expiry);
    }

    #[test]
    fn expired_and_paused_states_map_without_access() {
        let expired = parse_purchase(&purchase("SUBSCRIPTION_STATE_EXPIRED", false));
        assert_eq!(
            update_from_purchase("tok", &expired, now()).unwrap().state,
            SubState::Expired
        );
        let paused = parse_purchase(&purchase("SUBSCRIPTION_STATE_PAUSED", false));
        assert_eq!(
            update_from_purchase("tok", &paused, now()).unwrap().state,
            SubState::Paused
        );
    }

    #[test]
    fn unknown_state_is_ignored() {
        let parsed = parse_purchase(&purchase("SUBSCRIPTION_STATE_FUTURE", false));
        assert!(update_from_purchase("tok", &parsed, now()).is_none());
    }

    #[test]
    fn developer_notification_parses_the_purchase_token() {
        let data = json!({
            "packageName": "com.lazarovco.budgetwarden",
            "subscriptionNotification": {
                "notificationType": 2,
                "purchaseToken": "token-123",
                "subscriptionId": "cloud.monthly"
            }
        });
        let parsed: DeveloperNotification = serde_json::from_value(data).unwrap();
        let notification = parsed.subscription_notification.unwrap();
        assert_eq!(notification.purchase_token, "token-123");
        assert_eq!(notification.notification_type, 2);
    }
}
