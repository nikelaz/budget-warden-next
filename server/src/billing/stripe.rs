//! Stripe Managed Payments adapter for desktop and web subscriptions.
//!
//! Checkout creates a Stripe subscription with Budget Warden account metadata.
//! Stripe webhook signatures are verified before provider-neutral entitlement
//! state is updated.

use chrono::{DateTime, Utc};
use hmac::{Hmac, Mac};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::Sha256;
use subtle::ConstantTimeEq;
use uuid::Uuid;

use super::{BillingClients, Provider, SubState, SubscriptionUpdate, provider_unavailable};
use crate::{config::StripeConfig, errors::ApiResult};

const API_BASE_URL: &str = "https://api.stripe.com";
const ACCOUNT_METADATA_KEY: &str = "budget_warden_account_id";

#[derive(Debug, Serialize)]
pub struct CheckoutSession {
    pub checkout_url: String,
    pub session_id: String,
}

/// Creates a hosted Checkout Session for the configured Managed Payments price.
pub async fn create_checkout(
    clients: &BillingClients,
    config: &StripeConfig,
    account_id: Uuid,
) -> ApiResult<CheckoutSession> {
    let (Some(secret_key), Some(price_id), Some(success_url), Some(cancel_url)) = (
        config.secret_key.as_deref(),
        config.price_id.as_deref(),
        config.success_url.as_deref(),
        config.cancel_url.as_deref(),
    ) else {
        return Err(provider_unavailable(
            "Stripe checkout is not fully configured.",
        ));
    };

    let account_id = account_id.to_string();
    let form: Vec<(String, String)> = vec![
        ("mode".to_owned(), "subscription".to_owned()),
        ("line_items[0][price]".to_owned(), price_id.to_owned()),
        ("line_items[0][quantity]".to_owned(), "1".to_owned()),
        ("success_url".to_owned(), success_url.to_owned()),
        ("cancel_url".to_owned(), cancel_url.to_owned()),
        ("client_reference_id".to_owned(), account_id.clone()),
        (
            format!("metadata[{ACCOUNT_METADATA_KEY}]"),
            account_id.clone(),
        ),
        (
            format!("subscription_data[metadata][{ACCOUNT_METADATA_KEY}]"),
            account_id,
        ),
        ("managed_payments[enabled]".to_owned(), "true".to_owned()),
    ];
    let response = clients
        .http
        .post(format!("{API_BASE_URL}/v1/checkout/sessions"))
        .basic_auth(secret_key, Some(""))
        .form(&form)
        .send()
        .await
        .map_err(|_| provider_unavailable("Stripe could not be reached."))?;
    if !response.status().is_success() {
        tracing::error!(status = %response.status(), "stripe checkout session creation failed");
        return Err(provider_unavailable(
            "Stripe could not create a checkout session.",
        ));
    }
    let body: Value = response
        .json()
        .await
        .map_err(|_| provider_unavailable("Stripe returned an unreadable checkout session."))?;
    let session_id = body
        .get("id")
        .and_then(Value::as_str)
        .ok_or_else(|| provider_unavailable("Stripe returned no checkout session ID."))?
        .to_owned();
    let checkout_url = body
        .get("url")
        .and_then(Value::as_str)
        .ok_or_else(|| provider_unavailable("Stripe returned no checkout URL."))?
        .to_owned();
    Ok(CheckoutSession {
        checkout_url,
        session_id,
    })
}

#[derive(Debug, PartialEq, Eq)]
pub enum WebhookError {
    MissingSignature,
    BadSignature,
    StaleTimestamp,
}

/// Verifies Stripe's `t=...,v1=...` signature over `"<timestamp>.<raw body>"`.
/// Multiple v1 signatures are accepted during endpoint-secret rotation.
pub fn verify_webhook_signature(
    secret: &str,
    header: Option<&str>,
    body: &[u8],
    now_unix: i64,
    tolerance_seconds: i64,
) -> Result<(), WebhookError> {
    let header = header.ok_or(WebhookError::MissingSignature)?;
    let mut timestamp_text = None;
    let mut signatures = Vec::new();
    for part in header.split(',') {
        match part.trim().split_once('=') {
            Some(("t", value)) => timestamp_text = Some(value.to_owned()),
            Some(("v1", value)) => signatures.push(value.to_owned()),
            _ => {}
        }
    }
    let timestamp_text = timestamp_text.ok_or(WebhookError::MissingSignature)?;
    if signatures.is_empty() {
        return Err(WebhookError::MissingSignature);
    }
    let timestamp = timestamp_text
        .parse::<i64>()
        .map_err(|_| WebhookError::MissingSignature)?;
    if now_unix.abs_diff(timestamp) > tolerance_seconds.max(0) as u64 {
        return Err(WebhookError::StaleTimestamp);
    }

    let mut mac = Hmac::<Sha256>::new_from_slice(secret.as_bytes())
        .map_err(|_| WebhookError::BadSignature)?;
    mac.update(timestamp_text.as_bytes());
    mac.update(b".");
    mac.update(body);
    let expected = hex(&mac.finalize().into_bytes());
    if signatures
        .iter()
        .any(|candidate| bool::from(candidate.as_bytes().ct_eq(expected.as_bytes())))
    {
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
pub struct StripeEvent {
    pub id: String,
    #[serde(rename = "type")]
    pub event_type: String,
    pub created: i64,
    pub data: StripeEventData,
}

#[derive(Debug, Deserialize)]
pub struct StripeEventData {
    pub object: Value,
}

/// Maps a Stripe subscription object to provider-neutral entitlement state.
pub fn update_from_subscription(
    data: &Value,
    observed_at: DateTime<Utc>,
) -> Option<SubscriptionUpdate> {
    let subscription_id = data.get("id")?.as_str()?.to_owned();
    let status = data.get("status")?.as_str()?;
    let account_id = data
        .pointer(&format!("/metadata/{ACCOUNT_METADATA_KEY}"))
        .and_then(Value::as_str)
        .and_then(|value| Uuid::parse_str(value).ok());
    let period_end = subscription_period_end(data);
    let access_until = match (period_end, epoch_time(data.get("cancel_at"))) {
        (Some(period_end), Some(cancel_at)) => Some(period_end.min(cancel_at)),
        (None, Some(cancel_at)) => Some(cancel_at),
        (period_end, None) => period_end,
    };
    let scheduled_cancel = data
        .get("cancel_at_period_end")
        .and_then(Value::as_bool)
        .unwrap_or(false)
        || data.get("cancel_at").and_then(Value::as_i64).is_some();

    let (state, access_until, auto_renews) = match status {
        "active" | "trialing" => (
            SubState::Active,
            access_until.or_else(|| epoch_time(data.get("trial_end"))),
            !scheduled_cancel,
        ),
        "past_due" => (SubState::PaymentRetry, access_until, !scheduled_cancel),
        "paused" => (SubState::Paused, None, false),
        "canceled" => (
            SubState::Expired,
            epoch_time(data.get("ended_at")).or_else(|| epoch_time(data.get("canceled_at"))),
            false,
        ),
        "unpaid" => (SubState::Revoked, None, false),
        "incomplete" => (SubState::Pending, None, false),
        "incomplete_expired" => (SubState::Expired, None, false),
        _ => return None,
    };

    Some(SubscriptionUpdate {
        provider: Provider::Stripe,
        provider_subscription_id: subscription_id,
        account_id,
        state,
        access_until,
        auto_renews,
        management_url: None,
        provider_status: status.to_owned(),
        provider_updated_at: observed_at,
    })
}

fn subscription_period_end(subscription: &Value) -> Option<DateTime<Utc>> {
    epoch_time(subscription.get("current_period_end")).or_else(|| {
        subscription
            .pointer("/items/data/0/current_period_end")
            .and_then(|value| DateTime::from_timestamp(value.as_i64()?, 0))
    })
}

fn epoch_time(value: Option<&Value>) -> Option<DateTime<Utc>> {
    DateTime::from_timestamp(value?.as_i64()?, 0)
}

/// Retrieves the provider's current subscription state for reconciliation.
pub async fn fetch_subscription(
    clients: &BillingClients,
    config: &StripeConfig,
    subscription_id: &str,
) -> ApiResult<Value> {
    let secret_key = config
        .secret_key
        .as_deref()
        .ok_or_else(|| provider_unavailable("Stripe is not configured."))?;
    let response = clients
        .http
        .get(format!("{API_BASE_URL}/v1/subscriptions/{subscription_id}"))
        .basic_auth(secret_key, Some(""))
        .send()
        .await
        .map_err(|_| provider_unavailable("Stripe could not be reached."))?;
    if !response.status().is_success() {
        tracing::error!(status = %response.status(), "stripe subscription lookup failed");
        return Err(provider_unavailable(
            "Stripe did not return the subscription.",
        ));
    }
    response
        .json()
        .await
        .map_err(|_| provider_unavailable("Stripe returned an unreadable subscription."))
}

/// Creates a short-lived Billing Portal session for the customer's subscription.
pub async fn create_portal_session(
    clients: &BillingClients,
    config: &StripeConfig,
    subscription_id: &str,
) -> ApiResult<String> {
    let (Some(secret_key), Some(return_url)) = (
        config.secret_key.as_deref(),
        config.portal_return_url.as_deref(),
    ) else {
        return Err(provider_unavailable(
            "Stripe customer portal is not fully configured.",
        ));
    };
    let subscription = fetch_subscription(clients, config, subscription_id).await?;
    let customer = subscription
        .get("customer")
        .and_then(|value| value.as_str().or_else(|| value.get("id")?.as_str()))
        .ok_or_else(|| provider_unavailable("Stripe returned no subscription customer."))?;
    let form = [
        ("customer", customer.to_owned()),
        ("return_url", return_url.to_owned()),
    ];
    let response = clients
        .http
        .post(format!("{API_BASE_URL}/v1/billing_portal/sessions"))
        .basic_auth(secret_key, Some(""))
        .form(&form)
        .send()
        .await
        .map_err(|_| provider_unavailable("Stripe could not be reached."))?;
    if !response.status().is_success() {
        tracing::error!(status = %response.status(), "stripe portal session creation failed");
        return Err(provider_unavailable(
            "Stripe could not create a customer portal session.",
        ));
    }
    let body: Value = response
        .json()
        .await
        .map_err(|_| provider_unavailable("Stripe returned an unreadable portal session."))?;
    body.get("url")
        .and_then(Value::as_str)
        .map(str::to_owned)
        .ok_or_else(|| provider_unavailable("Stripe returned no customer portal URL."))
}

#[derive(Debug, PartialEq, Eq)]
pub enum CancelOutcome {
    Canceled,
    AlreadyCanceled,
}

#[derive(Debug, PartialEq, Eq)]
pub enum CancelFailure {
    Transient(String),
    Permanent(String),
}

/// Cancels a subscription immediately for account deletion.
pub async fn cancel_subscription(
    clients: &BillingClients,
    config: &StripeConfig,
    subscription_id: &str,
) -> Result<CancelOutcome, CancelFailure> {
    let secret_key = config
        .secret_key
        .as_deref()
        .ok_or_else(|| CancelFailure::Transient("Stripe is not configured".to_owned()))?;
    let response = clients
        .http
        .delete(format!("{API_BASE_URL}/v1/subscriptions/{subscription_id}"))
        .basic_auth(secret_key, Some(""))
        .send()
        .await
        .map_err(|error| CancelFailure::Transient(error.to_string()))?;
    if response.status().is_success() {
        return Ok(CancelOutcome::Canceled);
    }
    if response.status() == reqwest::StatusCode::NOT_FOUND {
        return Ok(CancelOutcome::AlreadyCanceled);
    }
    let status = response.status();
    let failure = format!("Stripe rejected cancellation with {status}");
    if status.is_server_error() || status == reqwest::StatusCode::TOO_MANY_REQUESTS {
        Err(CancelFailure::Transient(failure))
    } else {
        Err(CancelFailure::Permanent(failure))
    }
}
