//! HTTP handlers for store purchases, verification, and provider webhooks.
//!
//! Account-facing purchase routes require a session. Webhook routes are public
//! and authenticate the sender with the provider's signature or token; they
//! always record the event ID first so a redelivered event is a no-op.

use axum::{
    Extension, Json, Router,
    body::Bytes,
    extract::State,
    http::{HeaderMap, StatusCode, header::AUTHORIZATION},
    middleware,
    response::{IntoResponse, Response},
    routing::post,
};
use base64::{Engine as _, engine::general_purpose::STANDARD};
use chrono::Utc;
use serde::Deserialize;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use uuid::Uuid;

use super::{ApplyOutcome, Provider, apple, apply_update, google, stripe};
use crate::{
    auth::{self, AuthenticatedAccount},
    config::Config,
    errors::{ApiError, ApiResult, RequestContext, database_error},
    provider::{ProviderError, ProviderName},
    state::AppState,
};

pub fn routes(state: AppState) -> Router<AppState> {
    let protected = middleware::from_fn_with_state(state.clone(), auth::require_auth);
    Router::new()
        .route(
            "/v1/billing/stripe/checkout",
            post(stripe_checkout).route_layer(protected.clone()),
        )
        .route(
            "/v1/billing/stripe/portal",
            post(stripe_portal).route_layer(protected.clone()),
        )
        .route(
            "/v1/billing/apple/verify",
            post(apple_verify).route_layer(protected.clone()),
        )
        .route(
            "/v1/billing/google/verify",
            post(google_verify).route_layer(protected),
        )
        .route("/v1/billing/stripe/webhook", post(stripe_webhook))
        .route("/v1/billing/apple/notifications", post(apple_notifications))
        .route(
            "/v1/billing/google/notifications",
            post(google_notifications),
        )
        .route(
            "/v1/auth/apple/server-notifications",
            post(apple_server_notifications),
        )
}

fn respond(result: ApiResult<Value>, context: RequestContext) -> Response {
    match result {
        Ok(value) => (StatusCode::OK, Json(value)).into_response(),
        Err(error) => error.into_response(context),
    }
}

fn store_proof_error(detail: &str) -> ApiError {
    ApiError::new(
        StatusCode::UNPROCESSABLE_ENTITY,
        "invalid_store_proof",
        detail.to_owned(),
    )
}

fn account_mismatch() -> ApiError {
    ApiError::new(
        StatusCode::FORBIDDEN,
        "account_mismatch",
        "This purchase is bound to a different Budget Warden account.",
    )
}

fn owned_elsewhere() -> ApiError {
    ApiError::new(
        StatusCode::CONFLICT,
        "subscription_owned_by_another_account",
        "This subscription is already linked to another Budget Warden account. Contact support to transfer it.",
    )
}

fn outcome_value(outcome: ApplyOutcome) -> ApiResult<Value> {
    match outcome {
        ApplyOutcome::Applied => Ok(json!({ "status": "applied" })),
        ApplyOutcome::Stale => Ok(json!({ "status": "current" })),
        ApplyOutcome::Unlinked => Err(store_proof_error(
            "The purchase is not linked to an account.",
        )),
        ApplyOutcome::OwnedByAnotherAccount => Err(owned_elsewhere()),
    }
}

/// Records an incoming event. Returns `true` when it was already processed.
async fn already_processed(
    state: &AppState,
    provider: Provider,
    event_id: &str,
    body_digest: &[u8],
) -> ApiResult<bool> {
    let processed = sqlx::query_scalar::<_, Option<chrono::DateTime<Utc>>>(
        "SELECT processed_at FROM billing_events WHERE billing_provider = $1 AND provider_event_id = $2",
    )
    .bind(provider.as_str())
    .bind(event_id)
    .fetch_optional(&state.db)
    .await
    .map_err(database_error)?;
    if let Some(processed_at) = processed {
        return Ok(processed_at.is_some());
    }
    sqlx::query(
        "INSERT INTO billing_events (id, billing_provider, provider_event_id, payload_digest) \
         VALUES ($1, $2, $3, $4) ON CONFLICT (billing_provider, provider_event_id) DO NOTHING",
    )
    .bind(Uuid::new_v4())
    .bind(provider.as_str())
    .bind(event_id)
    .bind(body_digest)
    .execute(&state.db)
    .await
    .map_err(database_error)?;
    Ok(false)
}

async fn mark_processed(state: &AppState, provider: Provider, event_id: &str) -> ApiResult<()> {
    sqlx::query(
        "UPDATE billing_events SET processed_at = clock_timestamp() \
         WHERE billing_provider = $1 AND provider_event_id = $2",
    )
    .bind(provider.as_str())
    .bind(event_id)
    .execute(&state.db)
    .await
    .map_err(database_error)?;
    Ok(())
}

fn digest(body: &[u8]) -> Vec<u8> {
    Sha256::digest(body).to_vec()
}

fn trusted_root(config: &Config) -> &[u8] {
    config
        .storekit
        .root_certificate_der
        .as_deref()
        .unwrap_or(apple::APPLE_ROOT_CA_G3_DER)
}

// ------------------------------------------------ Stripe Managed Payments

async fn stripe_checkout(
    State(state): State<AppState>,
    Extension(account): Extension<AuthenticatedAccount>,
    Extension(context): Extension<RequestContext>,
) -> Response {
    let result = async {
        let active = sqlx::query_scalar::<_, bool>(
            "SELECT EXISTS (SELECT 1 FROM entitlements WHERE account_id = $1 AND can_write \
             AND state IN ('active', 'grace') \
             AND (effective_expires_at IS NULL OR effective_expires_at > clock_timestamp()))",
        )
        .bind(account.0)
        .fetch_one(&state.db)
        .await
        .map_err(database_error)?;
        if active {
            return Err(ApiError::new(
                StatusCode::CONFLICT,
                "entitlement_already_active",
                "This account already has an active subscription.",
            ));
        }
        let link = stripe::create_checkout(&state.billing, &state.config.stripe, account.0).await?;
        serde_json::to_value(link).map_err(ApiError::internal)
    }
    .await;
    respond(result, context)
}

async fn stripe_portal(
    State(state): State<AppState>,
    Extension(account): Extension<AuthenticatedAccount>,
    Extension(context): Extension<RequestContext>,
) -> Response {
    let result = async {
        let subscription_id = sqlx::query_scalar::<_, String>(
            "SELECT provider_subscription_id FROM subscriptions \
             WHERE account_id = $1 AND billing_provider = 'stripe' \
               AND state IN ('active', 'grace', 'payment_retry') \
               AND (access_until IS NULL OR access_until > clock_timestamp()) \
             ORDER BY verified_at DESC LIMIT 1",
        )
        .bind(account.0)
        .fetch_optional(&state.db)
        .await
        .map_err(database_error)?
        .ok_or_else(|| {
            ApiError::new(
                StatusCode::NOT_FOUND,
                "not_found",
                "No active Stripe subscription was found for this account.",
            )
        })?;
        let portal_url =
            stripe::create_portal_session(&state.billing, &state.config.stripe, &subscription_id)
                .await?;
        Ok(json!({ "portal_url": portal_url }))
    }
    .await;
    respond(result, context)
}

async fn stripe_webhook(
    State(state): State<AppState>,
    Extension(context): Extension<RequestContext>,
    headers: HeaderMap,
    body: Bytes,
) -> Response {
    let result = stripe_webhook_inner(&state, &headers, &body).await;
    respond(result, context)
}

async fn stripe_webhook_inner(
    state: &AppState,
    headers: &HeaderMap,
    body: &[u8],
) -> ApiResult<Value> {
    let config = &state.config.stripe;
    let secret = config
        .webhook_secret
        .as_deref()
        .ok_or_else(|| super::provider_unavailable("Stripe webhooks are not configured."))?;
    let signature = headers
        .get("Stripe-Signature")
        .and_then(|value| value.to_str().ok());
    stripe::verify_webhook_signature(
        secret,
        signature,
        body,
        Utc::now().timestamp(),
        config.webhook_tolerance_seconds,
    )
    .map_err(|_| {
        ApiError::new(
            StatusCode::UNAUTHORIZED,
            "invalid_webhook_signature",
            "The Stripe webhook signature could not be verified.",
        )
    })?;

    let event: stripe::StripeEvent = serde_json::from_slice(body).map_err(|_| {
        ApiError::new(
            StatusCode::BAD_REQUEST,
            "invalid_request",
            "The Stripe webhook body is not a valid event.",
        )
    })?;
    let event_time = chrono::DateTime::from_timestamp(event.created, 0).ok_or_else(|| {
        ApiError::new(
            StatusCode::BAD_REQUEST,
            "invalid_request",
            "The Stripe event timestamp is invalid.",
        )
    })?;
    if already_processed(state, Provider::Stripe, &event.id, &digest(body)).await? {
        return Ok(json!({ "status": "duplicate" }));
    }
    let update = if event.event_type.starts_with("customer.subscription.") {
        stripe::update_from_subscription(&event.data.object, event_time)
    } else {
        None
    };
    if let Some(update) = update {
        let outcome = apply_update(&state.db, &state.config, &update).await?;
        tracing::info!(event_id = %event.id, ?outcome, "stripe subscription event processed");
    }
    mark_processed(state, Provider::Stripe, &event.id).await?;
    Ok(json!({ "status": "ok" }))
}

// ---------------------------------------------------------------- Apple

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct AppleVerifyRequest {
    signed_transaction: String,
}

async fn apple_verify(
    State(state): State<AppState>,
    Extension(account): Extension<AuthenticatedAccount>,
    Extension(context): Extension<RequestContext>,
    body: Bytes,
) -> Response {
    let result = async {
        let request: AppleVerifyRequest = serde_json::from_slice(&body).map_err(|_| {
            ApiError::new(
                StatusCode::BAD_REQUEST,
                "invalid_request",
                "signed_transaction is required.",
            )
        })?;
        let now = Utc::now();
        let root = trusted_root(&state.config);
        let claims = apple::verify_signed_payload(&request.signed_transaction, root, now).map_err(
            |error| {
                tracing::warn!(?error, "apple transaction verification failed");
                store_proof_error("The App Store transaction could not be verified.")
            },
        )?;
        let transaction: apple::TransactionInfo = serde_json::from_value(claims)
            .map_err(|_| store_proof_error("The App Store transaction is malformed."))?;
        if let Some(bundle) = state.config.storekit.bundle_id.as_deref()
            && transaction.bundle_id.as_deref() != Some(bundle)
        {
            return Err(store_proof_error("The transaction belongs to another app."));
        }
        let bound = transaction
            .app_account_token
            .as_deref()
            .and_then(|token| Uuid::parse_str(token).ok());
        if bound != Some(account.0) {
            return Err(account_mismatch());
        }

        let renewal = match apple::fetch_latest_signed(
            &state.billing,
            &state.config.storekit,
            &transaction.original_transaction_id,
            now,
        )
        .await
        {
            Ok(Some((_, Some(renewal_jws)))) => Some(
                apple::verify_signed_payload(&renewal_jws, root, now)
                    .ok()
                    .and_then(|claims| serde_json::from_value::<apple::RenewalInfo>(claims).ok())
                    .ok_or_else(|| store_proof_error("The renewal information is malformed."))?,
            ),
            Ok(_) => None,
            Err(_) => None,
        };
        let update = apple::update_from_transaction(&transaction, renewal.as_ref(), now);
        let outcome = apply_update(&state.db, &state.config, &update).await?;
        outcome_value(outcome)
    }
    .await;
    respond(result, context)
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct AppleNotificationBody {
    #[serde(rename = "signedPayload")]
    signed_payload: String,
}

async fn apple_notifications(
    State(state): State<AppState>,
    Extension(context): Extension<RequestContext>,
    body: Bytes,
) -> Response {
    let result = async {
        let request: AppleNotificationBody = serde_json::from_slice(&body).map_err(|_| {
            ApiError::new(StatusCode::BAD_REQUEST, "invalid_request", "signedPayload is required.")
        })?;
        let now = Utc::now();
        let payload = apple::parse_notification(&request.signed_payload, trusted_root(&state.config), now)
            .map_err(|error| {
                tracing::warn!(?error, "apple notification verification failed");
                ApiError::new(
                    StatusCode::UNAUTHORIZED,
                    "invalid_store_proof",
                    "The App Store notification could not be verified.",
                )
            })?;
        if let Some(bundle) = state.config.storekit.bundle_id.as_deref()
            && payload.data.as_ref().and_then(|data| data.bundle_id.as_deref()) != Some(bundle)
        {
            return Err(store_proof_error("The notification belongs to another app."));
        }
        if already_processed(&state, Provider::Apple, &payload.notification_uuid, &digest(&body)).await? {
            return Ok(json!({ "status": "duplicate" }));
        }
        if let Some((transaction, renewal)) =
            apple::decode_notification(&payload, trusted_root(&state.config), now)
                .map_err(|_| store_proof_error("The App Store notification data is malformed."))?
        {
            let update = apple::update_from_transaction(&transaction, renewal.as_ref(), now);
            let outcome = apply_update(&state.db, &state.config, &update).await?;
            tracing::info!(notification = %payload.notification_type, ?outcome, "apple subscription notification processed");
        }
        mark_processed(&state, Provider::Apple, &payload.notification_uuid).await?;
        Ok(json!({ "status": "ok" }))
    }
    .await;
    respond(result, context)
}

// ---------------------------------------------------------------- Google

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct GoogleVerifyRequest {
    purchase_token: String,
}

async fn google_verify(
    State(state): State<AppState>,
    Extension(account): Extension<AuthenticatedAccount>,
    Extension(context): Extension<RequestContext>,
    body: Bytes,
) -> Response {
    let result = async {
        let request: GoogleVerifyRequest = serde_json::from_slice(&body).map_err(|_| {
            ApiError::new(StatusCode::BAD_REQUEST, "invalid_request", "purchase_token is required.")
        })?;
        let now = Utc::now();
        let purchase = google::fetch_purchase(
            &state.billing,
            &state.config.google_play,
            &request.purchase_token,
            now,
        )
        .await?
        .ok_or_else(|| store_proof_error("Google Play does not recognize this purchase."))?;
        match purchase.obfuscated_account_id.as_deref() {
            None => {
                return Err(ApiError::new(
                    StatusCode::UNPROCESSABLE_ENTITY,
                    "purchase_unbound",
                    "Set the purchase's obfuscated account ID to this Budget Warden account before verifying.",
                ));
            }
            Some(bound) if Uuid::parse_str(bound).ok() != Some(account.0) => {
                return Err(account_mismatch());
            }
            Some(_) => {}
        }
        let update = google::update_from_purchase(&request.purchase_token, &purchase, now)
            .ok_or_else(|| store_proof_error("Google Play reported an unknown subscription state."))?;
        let outcome = apply_update(&state.db, &state.config, &update).await?;
        outcome_value(outcome)
    }
    .await;
    respond(result, context)
}

#[derive(Deserialize)]
struct PushEnvelope {
    message: PushMessage,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct PushMessage {
    data: Option<String>,
    message_id: String,
}

async fn google_notifications(
    State(state): State<AppState>,
    Extension(context): Extension<RequestContext>,
    headers: HeaderMap,
    body: Bytes,
) -> Response {
    let result = async {
        let config = &state.config.google_play;
        let audience = config.pubsub_audience.as_deref().ok_or_else(|| {
            super::provider_unavailable("Google notifications are not configured.")
        })?;
        let token = headers
            .get(AUTHORIZATION)
            .and_then(|value| value.to_str().ok())
            .and_then(|value| value.strip_prefix("Bearer "))
            .ok_or_else(unauthorized_push)?;
        let claims = state
            .provider_verifier
            .verify_signed_jwt(ProviderName::Google, token, audience)
            .await
            .map_err(|error| match error {
                ProviderError::Unavailable => {
                    super::provider_unavailable("Google keys are unavailable.")
                }
                ProviderError::InvalidProof => unauthorized_push(),
            })?;
        let expected_sender = config.pubsub_service_account.as_deref().ok_or_else(|| {
            super::provider_unavailable("Google notifications are not configured.")
        })?;
        if claims.get("email").and_then(Value::as_str) != Some(expected_sender)
            || claims.get("email_verified").and_then(Value::as_bool) != Some(true)
        {
            return Err(unauthorized_push());
        }

        let envelope: PushEnvelope = serde_json::from_slice(&body).map_err(|_| {
            ApiError::new(
                StatusCode::BAD_REQUEST,
                "invalid_request",
                "The push body is not valid.",
            )
        })?;
        if already_processed(
            &state,
            Provider::Google,
            &envelope.message.message_id,
            &digest(&body),
        )
        .await?
        {
            return Ok(json!({ "status": "duplicate" }));
        }
        let data = envelope
            .message
            .data
            .as_deref()
            .map(|encoded| STANDARD.decode(encoded))
            .transpose()
            .map_err(|_| {
                ApiError::new(
                    StatusCode::BAD_REQUEST,
                    "invalid_request",
                    "The push data is not base64.",
                )
            })?
            .map(|bytes| serde_json::from_slice::<google::DeveloperNotification>(&bytes))
            .transpose()
            .map_err(|_| {
                ApiError::new(
                    StatusCode::BAD_REQUEST,
                    "invalid_request",
                    "The notification is not valid.",
                )
            })?;

        if let Some(notification) = data
            && notification.package_name.as_deref() == config.package_name.as_deref()
            && let Some(subscription) = notification.subscription_notification
        {
            let now = Utc::now();
            tracing::info!(
                notification_type = subscription.notification_type,
                "google subscription notification received"
            );
            match google::fetch_purchase(&state.billing, config, &subscription.purchase_token, now)
                .await?
            {
                Some(purchase) => {
                    if let Some(update) =
                        google::update_from_purchase(&subscription.purchase_token, &purchase, now)
                    {
                        let outcome = apply_update(&state.db, &state.config, &update).await?;
                        tracing::info!(?outcome, "google subscription notification processed");
                    }
                }
                None => tracing::warn!("google notification referenced an unknown purchase token"),
            }
        }
        mark_processed(&state, Provider::Google, &envelope.message.message_id).await?;
        Ok(json!({ "status": "ok" }))
    }
    .await;
    respond(result, context)
}

fn unauthorized_push() -> ApiError {
    ApiError::new(
        StatusCode::UNAUTHORIZED,
        "invalid_webhook_signature",
        "The notification could not be authenticated.",
    )
}

// ------------------------------------------------- Sign in with Apple events

#[derive(Deserialize)]
struct AppleServerNotification {
    payload: String,
}

#[derive(Deserialize)]
struct AppleServerEvent {
    #[serde(rename = "type")]
    event_type: String,
    sub: String,
}

async fn apple_server_notifications(
    State(state): State<AppState>,
    Extension(context): Extension<RequestContext>,
    body: Bytes,
) -> Response {
    let result = async {
        let request: AppleServerNotification = serde_json::from_slice(&body).map_err(|_| {
            ApiError::new(StatusCode::BAD_REQUEST, "invalid_request", "payload is required.")
        })?;
        let mut claims = None;
        for client_id in state.config.apple_auth.client_ids.values() {
            if let Ok(verified) = state
                .provider_verifier
                .verify_signed_jwt(ProviderName::Apple, &request.payload, client_id)
                .await
            {
                claims = Some(verified);
                break;
            }
        }
        let claims = claims.ok_or_else(unauthorized_push)?;
        let events = claims
            .get("events")
            .and_then(Value::as_str)
            .ok_or_else(|| store_proof_error("The notification has no events."))?;
        let event: AppleServerEvent = serde_json::from_str(events)
            .map_err(|_| store_proof_error("The notification event is malformed."))?;

        let mut tx = state.db.begin().await.map_err(database_error)?;
        let accounts = sqlx::query_scalar::<_, Uuid>(
            "SELECT account_id FROM auth_identities WHERE provider = 'apple' AND subject = $1 FOR UPDATE",
        )
        .bind(&event.sub)
        .fetch_all(&mut *tx)
        .await
        .map_err(database_error)?;
        for account_id in accounts {
            match event.event_type.as_str() {
                "consent-revoked" => {
                    super::revoke_account_sessions(&mut tx, account_id).await?;
                }
                "account-delete" => {
                    schedule_account_deletion(&mut tx, account_id).await?;
                }
                _ => {}
            }
        }
        tx.commit().await.map_err(database_error)?;
        Ok(json!({ "status": "ok" }))
    }
    .await;
    respond(result, context)
}

/// Schedules deletion for an account whose identity provider requested it,
/// matching the self-service path: sessions end and desktop subscriptions are
/// queued for cancellation.
async fn schedule_account_deletion(
    tx: &mut sqlx::Transaction<'_, sqlx::Postgres>,
    account_id: Uuid,
) -> ApiResult<()> {
    sqlx::query(
        "UPDATE accounts SET deleted_at = COALESCE(deleted_at, clock_timestamp()), \
         deletion_purge_at = COALESCE(deletion_purge_at, clock_timestamp() + make_interval(days => 29)) \
         WHERE id = $1",
    )
    .bind(account_id)
    .execute(&mut **tx)
    .await
    .map_err(database_error)?;
    sqlx::query(
        "UPDATE subscriptions SET cancel_requested_at = COALESCE(cancel_requested_at, clock_timestamp()), \
         cancel_next_attempt_at = COALESCE(cancel_next_attempt_at, clock_timestamp()) \
         WHERE account_id = $1 AND billing_provider = 'stripe' AND auto_renews = true AND cancelled_at IS NULL",
    )
    .bind(account_id)
    .execute(&mut **tx)
    .await
    .map_err(database_error)?;
    super::revoke_account_sessions(tx, account_id).await
}
