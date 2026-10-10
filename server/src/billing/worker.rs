//! Background billing maintenance.
//!
//! Each pass does three things: retries provider cancellations queued by
//! account deletion, reconciles live subscriptions against the provider so a
//! missed webhook cannot leave stale access, and recomputes entitlements so
//! access ends on its paid-through date even when no event arrives.

use std::time::Duration;

use chrono::{DateTime, Utc};
use tokio::sync::watch;
use uuid::Uuid;

use super::{BillingClients, apple, google, paddle, recompute_entitlement};
use crate::{
    errors::{ApiResult, database_error},
    state::AppState,
};

pub async fn run_billing_worker(state: AppState, mut shutdown: watch::Receiver<bool>) {
    let mut interval = tokio::time::interval(Duration::from_secs(5 * 60));
    interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    loop {
        tokio::select! {
            changed = shutdown.changed() => {
                if changed.is_err() || *shutdown.borrow() {
                    break;
                }
            }
            _ = interval.tick() => {
                if let Err(error) = process_cancellations(&state).await {
                    tracing::error!(error = %error.detail, "billing cancellation pass failed");
                }
                if let Err(error) = reconcile_subscriptions(&state).await {
                    tracing::error!(error = %error.detail, "billing reconciliation pass failed");
                }
                if let Err(error) = recompute_all(&state).await {
                    tracing::error!(error = %error.detail, "entitlement recomputation failed");
                }
            }
        }
    }
}

/// Maximum backoff between provider cancellation attempts.
const MAX_CANCEL_BACKOFF_MINUTES: i64 = 360;

async fn process_cancellations(state: &AppState) -> ApiResult<()> {
    let due = sqlx::query_as::<_, (Uuid, String, i32)>(
        "SELECT id, provider_subscription_id, cancel_attempts FROM subscriptions \
         WHERE billing_provider = 'paddle' AND cancel_requested_at IS NOT NULL AND cancelled_at IS NULL \
           AND (cancel_next_attempt_at IS NULL OR cancel_next_attempt_at <= clock_timestamp()) \
         ORDER BY cancel_next_attempt_at NULLS FIRST LIMIT 20",
    )
    .fetch_all(&state.db)
    .await
    .map_err(database_error)?;

    for (id, provider_subscription_id, attempts) in due {
        let result = paddle::cancel_subscription(
            &state.billing,
            &state.config.paddle,
            &provider_subscription_id,
        )
        .await;
        match result {
            Ok(outcome) => {
                tracing::info!(%id, ?outcome, "paddle subscription cancellation accepted");
                sqlx::query(
                    "UPDATE subscriptions SET cancelled_at = clock_timestamp(), auto_renews = false, \
                     cancel_attempts = cancel_attempts + 1, cancel_next_attempt_at = NULL WHERE id = $1",
                )
                .bind(id)
                .execute(&state.db)
                .await
                .map_err(database_error)?;
            }
            Err(failure) => {
                let minutes = 2_i64
                    .saturating_pow(attempts.clamp(0, 16) as u32)
                    .min(MAX_CANCEL_BACKOFF_MINUTES);
                tracing::error!(%id, ?failure, "paddle subscription cancellation failed; will retry");
                sqlx::query(
                    "UPDATE subscriptions SET cancel_attempts = cancel_attempts + 1, \
                     cancel_next_attempt_at = clock_timestamp() + make_interval(mins => $2) WHERE id = $1",
                )
                .bind(id)
                .bind(minutes as i32)
                .execute(&state.db)
                .await
                .map_err(database_error)?;
            }
        }
    }
    Ok(())
}

async fn reconcile_subscriptions(state: &AppState) -> ApiResult<()> {
    let live = sqlx::query_as::<_, (String, String)>(
        "SELECT billing_provider, provider_subscription_id FROM subscriptions \
         WHERE state IN ('pending', 'active', 'grace', 'payment_retry', 'paused') \
         ORDER BY verified_at ASC LIMIT 50",
    )
    .fetch_all(&state.db)
    .await
    .map_err(database_error)?;

    let now = Utc::now();
    for (provider, provider_subscription_id) in live {
        let result = match provider.as_str() {
            "paddle" => {
                reconcile_paddle(&state.billing, state, &provider_subscription_id, now).await
            }
            "apple" => reconcile_apple(&state.billing, state, &provider_subscription_id, now).await,
            "google" => {
                reconcile_google(&state.billing, state, &provider_subscription_id, now).await
            }
            _ => Ok(()),
        };
        if let Err(error) = result {
            tracing::warn!(%provider, detail = %error.detail, "subscription reconciliation skipped");
        }
    }
    Ok(())
}

async fn reconcile_paddle(
    clients: &BillingClients,
    state: &AppState,
    subscription_id: &str,
    now: DateTime<Utc>,
) -> ApiResult<()> {
    let data = paddle::fetch_subscription(clients, &state.config.paddle, subscription_id).await?;
    if let Some(update) = paddle::update_from_subscription(&data, now) {
        super::apply_update(&state.db, &state.config, &update).await?;
    }
    Ok(())
}

async fn reconcile_apple(
    clients: &BillingClients,
    state: &AppState,
    original_transaction_id: &str,
    now: DateTime<Utc>,
) -> ApiResult<()> {
    let root = state
        .config
        .storekit
        .root_certificate_der
        .as_deref()
        .unwrap_or(apple::APPLE_ROOT_CA_G3_DER);
    let Some((transaction_jws, renewal_jws)) = apple::fetch_latest_signed(
        clients,
        &state.config.storekit,
        original_transaction_id,
        now,
    )
    .await?
    else {
        return Ok(());
    };
    let transaction: apple::TransactionInfo = serde_json::from_value(
        apple::verify_signed_payload(&transaction_jws, root, now)
            .map_err(|_| crate::errors::ApiError::internal("apple transaction did not verify"))?,
    )
    .map_err(crate::errors::ApiError::internal)?;
    let renewal = renewal_jws
        .map(|jws| apple::verify_signed_payload(&jws, root, now))
        .transpose()
        .map_err(|_| crate::errors::ApiError::internal("apple renewal did not verify"))?
        .map(serde_json::from_value::<apple::RenewalInfo>)
        .transpose()
        .map_err(crate::errors::ApiError::internal)?;
    let update = apple::update_from_transaction(&transaction, renewal.as_ref(), now);
    super::apply_update(&state.db, &state.config, &update).await?;
    Ok(())
}

async fn reconcile_google(
    clients: &BillingClients,
    state: &AppState,
    purchase_token: &str,
    now: DateTime<Utc>,
) -> ApiResult<()> {
    let Some(purchase) =
        google::fetch_purchase(clients, &state.config.google_play, purchase_token, now).await?
    else {
        return Ok(());
    };
    if let Some(update) = google::update_from_purchase(purchase_token, &purchase, now) {
        super::apply_update(&state.db, &state.config, &update).await?;
    }
    Ok(())
}

/// Recomputes every account's entitlement so paid-through dates take effect
/// without waiting for a provider event.
async fn recompute_all(state: &AppState) -> ApiResult<()> {
    let accounts = sqlx::query_scalar::<_, Uuid>(
        "SELECT DISTINCT account_id FROM subscriptions ORDER BY account_id LIMIT 500",
    )
    .fetch_all(&state.db)
    .await
    .map_err(database_error)?;
    for account_id in accounts {
        let mut tx = state.db.begin().await.map_err(database_error)?;
        sqlx::query("SELECT id FROM accounts WHERE id = $1 FOR UPDATE")
            .bind(account_id)
            .fetch_optional(&mut *tx)
            .await
            .map_err(database_error)?;
        recompute_entitlement(&mut tx, &state.config, account_id).await?;
        tx.commit().await.map_err(database_error)?;
    }
    Ok(())
}
