//! Paddle Billing adapter for desktop (Windows and Linux) subscriptions.
//!
//! Checkout is created server-side with the account ID in `custom_data`, so
//! webhooks can be correlated without trusting the client. Webhooks are
//! verified with the endpoint secret before any state changes.

use chrono::{DateTime, Utc};
use hmac::{Hmac, Mac};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::Sha256;
use subtle::ConstantTimeEq;
use uuid::Uuid;

use super::{BillingClients, Provider, SubState, SubscriptionUpdate, provider_unavailable};
use crate::{config::PaddleConfig, errors::ApiResult};

pub fn base_url(sandbox: bool) -> &'static str {
    if sandbox {
        "https://sandbox-api.paddle.com"
    } else {
        "https://api.paddle.com"
    }
}

#[derive(Debug, Serialize)]
pub struct CheckoutLink {
    pub checkout_url: String,
    pub transaction_id: String,
}

/// Creates a transaction for the configured price and returns the hosted
/// checkout URL. The customer completes payment in the browser.
pub async fn create_checkout(
    clients: &BillingClients,
    config: &PaddleConfig,
    account_id: Uuid,
) -> ApiResult<CheckoutLink> {
    let (Some(api_key), Some(price_id)) = (config.api_key.as_deref(), config.price_id.as_deref())
    else {
        return Err(provider_unavailable("Paddle checkout is not configured."));
    };
    let response = clients
        .http
        .post(format!("{}/transactions", base_url(config.sandbox)))
        .bearer_auth(api_key)
        .json(&json!({
            "items": [{ "price_id": price_id, "quantity": 1 }],
            "custom_data": { "account_id": account_id },
            "collection_mode": "automatic"
        }))
        .send()
        .await
        .map_err(|_| provider_unavailable("Paddle could not be reached."))?;
    if !response.status().is_success() {
        tracing::error!(status = %response.status(), "paddle transaction creation failed");
        return Err(provider_unavailable("Paddle could not create checkout."));
    }
    let body: Value = response
        .json()
        .await
        .map_err(|_| provider_unavailable("Paddle returned an unreadable checkout."))?;
    let transaction_id = body
        .pointer("/data/id")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_owned();
    let checkout_url = body
        .pointer("/data/checkout/url")
        .and_then(Value::as_str)
        .ok_or_else(|| provider_unavailable("Paddle did not return a checkout URL."))?
        .to_owned();
    Ok(CheckoutLink {
        checkout_url,
        transaction_id,
    })
}

#[derive(Debug, PartialEq, Eq)]
pub enum WebhookError {
    MissingSignature,
    BadSignature,
    StaleTimestamp,
}

/// Verifies `Paddle-Signature: ts=<unix>;h1=<hex>` over `"<ts>:<body>"`.
/// Multiple `h1` values are accepted during secret rotation.
pub fn verify_webhook_signature(
    secret: &str,
    header: Option<&str>,
    body: &[u8],
    now_unix: i64,
    tolerance_seconds: i64,
) -> Result<(), WebhookError> {
    let header = header.ok_or(WebhookError::MissingSignature)?;
    let mut timestamp = None;
    let mut signatures = Vec::new();
    for part in header.split(';') {
        match part.trim().split_once('=') {
            Some(("ts", value)) => timestamp = value.parse::<i64>().ok(),
            Some(("h1", value)) => signatures.push(value.to_owned()),
            _ => {}
        }
    }
    let timestamp = timestamp.ok_or(WebhookError::MissingSignature)?;
    if signatures.is_empty() {
        return Err(WebhookError::MissingSignature);
    }
    if (now_unix - timestamp).abs() > tolerance_seconds {
        return Err(WebhookError::StaleTimestamp);
    }

    let mut mac = Hmac::<Sha256>::new_from_slice(secret.as_bytes())
        .map_err(|_| WebhookError::BadSignature)?;
    mac.update(timestamp.to_string().as_bytes());
    mac.update(b":");
    mac.update(body);
    let expected = mac.finalize().into_bytes();
    let expected_hex = hex(&expected);
    let matched = signatures
        .iter()
        .any(|candidate| bool::from(candidate.as_bytes().ct_eq(expected_hex.as_bytes())));
    if matched {
        Ok(())
    } else {
        Err(WebhookError::BadSignature)
    }
}

fn hex(bytes: &[u8]) -> String {
    use std::fmt::Write;
    let mut out = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        let _ = write!(out, "{byte:02x}");
    }
    out
}

#[derive(Debug, Deserialize)]
pub struct PaddleEvent {
    pub event_id: String,
    pub event_type: String,
    pub occurred_at: DateTime<Utc>,
    pub data: Value,
}

/// Maps a Paddle subscription object to a provider-neutral update. Returns
/// `None` for statuses this service does not track.
pub fn update_from_subscription(
    data: &Value,
    observed_at: DateTime<Utc>,
) -> Option<SubscriptionUpdate> {
    let subscription_id = data.get("id")?.as_str()?.to_owned();
    let status = data.get("status")?.as_str()?;
    let account_id = data
        .pointer("/custom_data/account_id")
        .and_then(Value::as_str)
        .and_then(|value| Uuid::parse_str(value).ok());
    let period_end = parse_time(data.pointer("/current_billing_period/ends_at"));
    let next_billed = parse_time(data.get("next_billed_at"));
    let canceled_at = parse_time(data.get("canceled_at"));
    let scheduled_cancel = data
        .pointer("/scheduled_change/action")
        .and_then(Value::as_str)
        == Some("cancel");

    let (state, access_until, auto_renews) = match status {
        "active" | "trialing" => (
            SubState::Active,
            period_end.or(next_billed),
            !scheduled_cancel,
        ),
        "past_due" => (SubState::PaymentRetry, period_end.or(next_billed), true),
        "paused" => (SubState::Paused, None, false),
        // Paddle marks a subscription canceled when access actually ends.
        "canceled" => (
            SubState::Expired,
            Some(canceled_at.unwrap_or(observed_at)),
            false,
        ),
        _ => return None,
    };
    let management_url = data
        .pointer("/management_urls/update_payment_method")
        .and_then(Value::as_str)
        .map(str::to_owned);
    Some(SubscriptionUpdate {
        provider: Provider::Paddle,
        provider_subscription_id: subscription_id,
        account_id,
        state,
        access_until,
        auto_renews,
        management_url,
        provider_status: status.to_owned(),
        provider_updated_at: observed_at,
    })
}

fn parse_time(value: Option<&Value>) -> Option<DateTime<Utc>> {
    value
        .and_then(Value::as_str)
        .and_then(|text| DateTime::parse_from_rfc3339(text).ok())
        .map(|time| time.with_timezone(&Utc))
}

/// Fetches the current subscription object for reconciliation.
pub async fn fetch_subscription(
    clients: &BillingClients,
    config: &PaddleConfig,
    subscription_id: &str,
) -> ApiResult<Value> {
    let api_key = config
        .api_key
        .as_deref()
        .ok_or_else(|| provider_unavailable("Paddle is not configured."))?;
    let response = clients
        .http
        .get(format!(
            "{}/subscriptions/{subscription_id}",
            base_url(config.sandbox)
        ))
        .bearer_auth(api_key)
        .send()
        .await
        .map_err(|_| provider_unavailable("Paddle could not be reached."))?;
    if !response.status().is_success() {
        return Err(provider_unavailable(
            "Paddle did not return the subscription.",
        ));
    }
    let body: Value = response
        .json()
        .await
        .map_err(|_| provider_unavailable("Paddle returned an unreadable subscription."))?;
    body.get("data")
        .cloned()
        .ok_or_else(|| provider_unavailable("Paddle returned no subscription data."))
}

#[derive(Debug, PartialEq, Eq)]
pub enum CancelOutcome {
    Canceled,
    /// The provider reports the subscription was already canceled.
    AlreadyCanceled,
}

#[derive(Debug, PartialEq, Eq)]
pub enum CancelFailure {
    /// Retry later with backoff.
    Transient(String),
    /// Retrying will not help; surface to an operator.
    Permanent(String),
}

/// Requests immediate cancellation, used when an account is deleted.
pub async fn cancel_subscription(
    clients: &BillingClients,
    config: &PaddleConfig,
    subscription_id: &str,
) -> Result<CancelOutcome, CancelFailure> {
    let api_key = config
        .api_key
        .as_deref()
        .ok_or_else(|| CancelFailure::Transient("Paddle is not configured".to_string()))?;
    let response = clients
        .http
        .post(format!(
            "{}/subscriptions/{subscription_id}/cancel",
            base_url(config.sandbox)
        ))
        .bearer_auth(api_key)
        .json(&json!({ "effective_from": "immediately" }))
        .send()
        .await
        .map_err(|error| CancelFailure::Transient(error.to_string()))?;
    let status = response.status();
    if status.is_success() {
        return Ok(CancelOutcome::Canceled);
    }
    let body: Value = response.json().await.unwrap_or(Value::Null);
    let code = body
        .pointer("/error/code")
        .and_then(Value::as_str)
        .unwrap_or_default();
    if matches!(
        code,
        "subscription_canceled" | "subscription_already_canceled" | "subscription_locked"
    ) {
        return Ok(CancelOutcome::AlreadyCanceled);
    }
    if status.is_server_error() || status.as_u16() == 429 {
        Err(CancelFailure::Transient(format!(
            "Paddle returned {status}"
        )))
    } else {
        Err(CancelFailure::Permanent(format!(
            "Paddle rejected the cancellation with {status} {code}"
        )))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone;

    fn now() -> DateTime<Utc> {
        Utc.with_ymd_and_hms(2026, 3, 1, 12, 0, 0).unwrap()
    }

    fn sign(secret: &str, timestamp: i64, body: &[u8]) -> String {
        let mut mac = Hmac::<Sha256>::new_from_slice(secret.as_bytes()).unwrap();
        mac.update(timestamp.to_string().as_bytes());
        mac.update(b":");
        mac.update(body);
        format!("ts={timestamp};h1={}", hex(&mac.finalize().into_bytes()))
    }

    #[test]
    fn accepts_a_correctly_signed_fresh_webhook() {
        let body = br#"{"event_type":"subscription.created"}"#;
        let ts = now().timestamp();
        let header = sign("whsec_test", ts, body);
        assert_eq!(
            verify_webhook_signature("whsec_test", Some(&header), body, ts, 300),
            Ok(())
        );
    }

    #[test]
    fn rejects_tampered_bodies_wrong_secrets_and_missing_headers() {
        let body = b"{}";
        let ts = now().timestamp();
        let header = sign("whsec_test", ts, body);
        assert_eq!(
            verify_webhook_signature("whsec_test", Some(&header), b"{\"x\":1}", ts, 300),
            Err(WebhookError::BadSignature)
        );
        assert_eq!(
            verify_webhook_signature("other", Some(&header), body, ts, 300),
            Err(WebhookError::BadSignature)
        );
        assert_eq!(
            verify_webhook_signature("whsec_test", None, body, ts, 300),
            Err(WebhookError::MissingSignature)
        );
    }

    #[test]
    fn rejects_replays_outside_the_tolerance() {
        let body = b"{}";
        let old = now().timestamp() - 301;
        let header = sign("whsec_test", old, body);
        assert_eq!(
            verify_webhook_signature("whsec_test", Some(&header), body, now().timestamp(), 300),
            Err(WebhookError::StaleTimestamp)
        );
    }

    #[test]
    fn accepts_any_matching_signature_during_rotation() {
        let body = b"{}";
        let ts = now().timestamp();
        let good = sign("new", ts, body);
        let header = format!("ts={ts};h1=deadbeef;{}", good.split(';').nth(1).unwrap());
        assert_eq!(
            verify_webhook_signature("new", Some(&header), body, ts, 300),
            Ok(())
        );
    }

    #[test]
    fn active_subscription_uses_the_billing_period_end() {
        let data = json!({
            "id": "sub_1",
            "status": "active",
            "custom_data": { "account_id": "3f2a9c1e-5b7d-4e8a-9c21-7d4e5f6a8b90" },
            "current_billing_period": { "ends_at": "2026-04-01T00:00:00Z" },
            "management_urls": { "update_payment_method": "https://example.test/pay" }
        });
        let update = update_from_subscription(&data, now()).unwrap();
        assert_eq!(update.state, SubState::Active);
        assert!(update.auto_renews);
        assert_eq!(
            update.access_until,
            Some(Utc.with_ymd_and_hms(2026, 4, 1, 0, 0, 0).unwrap())
        );
        assert_eq!(
            update.account_id,
            Some(Uuid::parse_str("3f2a9c1e-5b7d-4e8a-9c21-7d4e5f6a8b90").unwrap())
        );
        assert_eq!(
            update.management_url.as_deref(),
            Some("https://example.test/pay")
        );
    }

    #[test]
    fn scheduled_cancellation_keeps_access_but_stops_renewal() {
        let data = json!({
            "id": "sub_1",
            "status": "active",
            "current_billing_period": { "ends_at": "2026-04-01T00:00:00Z" },
            "scheduled_change": { "action": "cancel" }
        });
        let update = update_from_subscription(&data, now()).unwrap();
        assert_eq!(update.state, SubState::Active);
        assert!(!update.auto_renews);
    }

    #[test]
    fn past_due_keeps_access_only_until_paid_through() {
        let data = json!({
            "id": "sub_1",
            "status": "past_due",
            "current_billing_period": { "ends_at": "2026-02-01T00:00:00Z" }
        });
        let update = update_from_subscription(&data, now()).unwrap();
        assert_eq!(update.state, SubState::PaymentRetry);
        assert!(update.auto_renews);
    }

    #[test]
    fn canceled_and_paused_map_to_terminal_access() {
        let canceled =
            json!({ "id": "sub_1", "status": "canceled", "canceled_at": "2026-02-15T00:00:00Z" });
        let update = update_from_subscription(&canceled, now()).unwrap();
        assert_eq!(update.state, SubState::Expired);
        assert!(!update.auto_renews);

        let paused = json!({ "id": "sub_1", "status": "paused" });
        assert_eq!(
            update_from_subscription(&paused, now()).unwrap().state,
            SubState::Paused
        );
    }

    #[test]
    fn unknown_statuses_are_ignored() {
        let data = json!({ "id": "sub_1", "status": "mystery" });
        assert!(update_from_subscription(&data, now()).is_none());
    }
}
