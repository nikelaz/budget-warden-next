//! Provider-neutral subscription state and entitlement computation.
//!
//! Every store adapter (Paddle, Apple, Google) reduces its provider data to a
//! [`SubscriptionUpdate`]. This module applies updates in provider-time order,
//! refuses to move a subscription between accounts, and recomputes the account
//! entitlement from all of its subscriptions.

pub mod apple;
pub mod google;
pub mod paddle;
pub mod routes;
pub mod worker;

use std::{sync::Arc, time::Instant};

use chrono::{DateTime, Duration as ChronoDuration, Utc};
use sqlx::{PgPool, Postgres, Transaction};
use tokio::sync::Mutex;
use uuid::Uuid;

use crate::{
    config::Config,
    errors::{ApiError, ApiResult, database_error},
    jobs,
};

/// Cloud budgets stay readable this long after paid access ends.
pub const READ_WINDOW_DAYS: i64 = 90;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Provider {
    Apple,
    Google,
    Paddle,
}

impl Provider {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Apple => "apple",
            Self::Google => "google",
            Self::Paddle => "paddle",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SubState {
    Pending,
    Active,
    Grace,
    PaymentRetry,
    Paused,
    Expired,
    Revoked,
}

impl SubState {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Pending => "pending",
            Self::Active => "active",
            Self::Grace => "grace",
            Self::PaymentRetry => "payment_retry",
            Self::Paused => "paused",
            Self::Expired => "expired",
            Self::Revoked => "revoked",
        }
    }

    fn parse(value: &str) -> Option<Self> {
        Some(match value {
            "pending" => Self::Pending,
            "active" => Self::Active,
            "grace" => Self::Grace,
            "payment_retry" => Self::PaymentRetry,
            "paused" => Self::Paused,
            "expired" => Self::Expired,
            "revoked" => Self::Revoked,
            _ => return None,
        })
    }

    /// Whether this state gives access at `now`, given the paid-through time.
    pub fn grants_access(self, access_until: Option<DateTime<Utc>>, now: DateTime<Utc>) -> bool {
        match self {
            Self::Active | Self::Grace => access_until.is_none_or(|until| until > now),
            // A failed renewal keeps access only until the paid-through date.
            Self::PaymentRetry => access_until.is_some_and(|until| until > now),
            Self::Pending | Self::Paused | Self::Expired | Self::Revoked => false,
        }
    }
}

#[derive(Clone, Debug)]
pub struct SubscriptionUpdate {
    pub provider: Provider,
    pub provider_subscription_id: String,
    /// Account named by the provider (custom data or app account token). The
    /// stored owner always wins; a conflicting claim is rejected.
    pub account_id: Option<Uuid>,
    pub state: SubState,
    pub access_until: Option<DateTime<Utc>>,
    pub auto_renews: bool,
    pub management_url: Option<String>,
    pub provider_status: String,
    /// Provider event or observation time, used to discard stale updates.
    pub provider_updated_at: DateTime<Utc>,
}

#[derive(Debug, PartialEq, Eq)]
pub enum ApplyOutcome {
    Applied,
    /// An equal-or-newer provider update was already applied.
    Stale,
    /// No account is linked to this subscription.
    Unlinked,
    /// The subscription belongs to a different Budget Warden account.
    OwnedByAnotherAccount,
}

/// Applies one update in its own transaction.
pub async fn apply_update(
    pool: &PgPool,
    config: &Config,
    update: &SubscriptionUpdate,
) -> ApiResult<ApplyOutcome> {
    let mut tx = pool.begin().await.map_err(database_error)?;
    let outcome = apply_update_tx(&mut tx, config, update).await?;
    tx.commit().await.map_err(database_error)?;
    Ok(outcome)
}

pub async fn apply_update_tx(
    tx: &mut Transaction<'_, Postgres>,
    config: &Config,
    update: &SubscriptionUpdate,
) -> ApiResult<ApplyOutcome> {
    // Lock order matches the deletion and retention paths: account first, then
    // its subscriptions. Read the owner before locking so the account lock can
    // come first.
    let owner = sqlx::query_scalar::<_, Uuid>(
        "SELECT account_id FROM subscriptions WHERE billing_provider = $1 AND provider_subscription_id = $2",
    )
    .bind(update.provider.as_str())
    .bind(&update.provider_subscription_id)
    .fetch_optional(&mut **tx)
    .await
    .map_err(database_error)?;
    let account_id = match (owner, update.account_id) {
        (Some(owner), Some(claimed)) if owner != claimed => {
            return Ok(ApplyOutcome::OwnedByAnotherAccount);
        }
        (Some(owner), _) => owner,
        (None, Some(claimed)) => claimed,
        (None, None) => return Ok(ApplyOutcome::Unlinked),
    };

    let locked = sqlx::query_scalar::<_, Uuid>("SELECT id FROM accounts WHERE id = $1 FOR UPDATE")
        .bind(account_id)
        .fetch_optional(&mut **tx)
        .await
        .map_err(database_error)?;
    if locked.is_none() {
        return Ok(ApplyOutcome::Unlinked);
    }

    let result = sqlx::query(
        "INSERT INTO subscriptions (id, account_id, billing_provider, provider_subscription_id, state, \
         access_until, auto_renews, management_url, verified_at, provider_status, provider_updated_at) \
         VALUES ($1, $2, $3, $4, $5, $6, $7, $8, clock_timestamp(), $9, $10) \
         ON CONFLICT (billing_provider, provider_subscription_id) DO UPDATE SET \
           state = EXCLUDED.state, \
           access_until = EXCLUDED.access_until, \
           auto_renews = EXCLUDED.auto_renews, \
           management_url = COALESCE(EXCLUDED.management_url, subscriptions.management_url), \
           provider_status = EXCLUDED.provider_status, \
           provider_updated_at = EXCLUDED.provider_updated_at, \
           verified_at = clock_timestamp() \
         WHERE subscriptions.account_id = EXCLUDED.account_id \
           AND (subscriptions.provider_updated_at IS NULL \
                OR subscriptions.provider_updated_at <= EXCLUDED.provider_updated_at)",
    )
    .bind(Uuid::new_v4())
    .bind(account_id)
    .bind(update.provider.as_str())
    .bind(&update.provider_subscription_id)
    .bind(update.state.as_str())
    .bind(update.access_until)
    .bind(update.auto_renews)
    .bind(&update.management_url)
    .bind(&update.provider_status)
    .bind(update.provider_updated_at)
    .execute(&mut **tx)
    .await
    .map_err(database_error)?;
    if result.rows_affected() == 0 {
        return Ok(ApplyOutcome::Stale);
    }

    recompute_entitlement(tx, config, account_id).await?;
    Ok(ApplyOutcome::Applied)
}

/// The account entitlement derived from its subscriptions.
#[derive(Debug, PartialEq, Eq)]
pub struct Entitlement {
    pub state: &'static str,
    pub can_write: bool,
    pub effective_expires_at: Option<DateTime<Utc>>,
    pub read_access_until: Option<DateTime<Utc>>,
}

/// Pure entitlement rules. Each subscription is `(state, paid-through)`.
pub fn compute_entitlement(
    subscriptions: &[(SubState, Option<DateTime<Utc>>)],
    now: DateTime<Utc>,
) -> Entitlement {
    let grants: Vec<_> = subscriptions
        .iter()
        .filter(|(state, until)| state.grants_access(*until, now))
        .collect();
    if !grants.is_empty() {
        let any_active = grants
            .iter()
            .any(|(state, _)| matches!(state, SubState::Active));
        let open_ended = grants.iter().any(|(_, until)| until.is_none());
        let effective_expires_at = if open_ended {
            None
        } else {
            grants.iter().filter_map(|(_, until)| *until).max()
        };
        return Entitlement {
            state: if any_active { "active" } else { "grace" },
            can_write: true,
            effective_expires_at,
            read_access_until: effective_expires_at
                .map(|until| until + ChronoDuration::days(READ_WINDOW_DAYS)),
        };
    }

    let usable: Vec<_> = subscriptions
        .iter()
        .filter(|(state, _)| *state != SubState::Revoked)
        .collect();
    if subscriptions.is_empty() {
        return Entitlement {
            state: "none",
            can_write: false,
            effective_expires_at: None,
            read_access_until: None,
        };
    }
    if usable.is_empty() {
        return Entitlement {
            state: "revoked",
            can_write: false,
            effective_expires_at: None,
            read_access_until: None,
        };
    }
    let ended_at = usable
        .iter()
        .map(|(_, until)| until.unwrap_or(now))
        .max()
        .unwrap_or(now);
    Entitlement {
        state: "expired",
        can_write: false,
        effective_expires_at: Some(ended_at),
        read_access_until: Some(ended_at + ChronoDuration::days(READ_WINDOW_DAYS)),
    }
}

/// Recomputes and stores the entitlement row for `account_id`. The development
/// grant is managed by startup seeding and is never overwritten here.
pub async fn recompute_entitlement(
    tx: &mut Transaction<'_, Postgres>,
    config: &Config,
    account_id: Uuid,
) -> ApiResult<()> {
    if config.dev_entitlement && config.dev_account_id == Some(account_id) {
        return Ok(());
    }
    let now = Utc::now();
    let rows = sqlx::query_as::<_, (String, Option<DateTime<Utc>>)>(
        "SELECT state, access_until FROM subscriptions WHERE account_id = $1",
    )
    .bind(account_id)
    .fetch_all(&mut **tx)
    .await
    .map_err(database_error)?;
    let subscriptions: Vec<(SubState, Option<DateTime<Utc>>)> = rows
        .into_iter()
        .filter_map(|(state, until)| SubState::parse(&state).map(|state| (state, until)))
        .collect();
    let next = compute_entitlement(&subscriptions, now);

    let previous_read_until = sqlx::query_scalar::<_, Option<DateTime<Utc>>>(
        "SELECT read_access_until FROM entitlements WHERE account_id = $1 FOR UPDATE",
    )
    .bind(account_id)
    .fetch_optional(&mut **tx)
    .await
    .map_err(database_error)?;

    // A renewal after the read window ended must not revive snapshots that
    // the retention rules already removed from access.
    let read_window_ended = previous_read_until
        .flatten()
        .is_some_and(|until| until <= now);
    if next.can_write && read_window_ended {
        jobs::purge_live_budgets(tx, account_id)
            .await
            .map_err(database_error)?;
    }

    sqlx::query(
        "INSERT INTO entitlements (account_id, state, can_write, effective_expires_at, read_access_until, updated_at) \
         VALUES ($1, $2, $3, $4, $5, clock_timestamp()) \
         ON CONFLICT (account_id) DO UPDATE SET state = EXCLUDED.state, can_write = EXCLUDED.can_write, \
           effective_expires_at = EXCLUDED.effective_expires_at, \
           read_access_until = EXCLUDED.read_access_until, updated_at = clock_timestamp()",
    )
    .bind(account_id)
    .bind(next.state)
    .bind(next.can_write)
    .bind(next.effective_expires_at)
    .bind(next.read_access_until)
    .execute(&mut **tx)
    .await
    .map_err(database_error)?;
    Ok(())
}

/// Marks an account's refresh-capable sessions revoked, used when a store or
/// identity provider withdraws consent.
pub async fn revoke_account_sessions(
    tx: &mut Transaction<'_, Postgres>,
    account_id: Uuid,
) -> ApiResult<()> {
    sqlx::query(
        "UPDATE sessions SET revoked_at = COALESCE(revoked_at, clock_timestamp()) WHERE account_id = $1",
    )
    .bind(account_id)
    .execute(&mut **tx)
    .await
    .map_err(database_error)?;
    Ok(())
}

/// Shared HTTP clients and cached provider tokens.
#[derive(Clone)]
pub struct BillingClients {
    pub http: reqwest::Client,
    pub google_token: Arc<Mutex<Option<CachedToken>>>,
}

#[derive(Clone)]
pub struct CachedToken {
    pub value: String,
    pub expires_at: Instant,
}

impl BillingClients {
    pub fn new() -> Result<Self, reqwest::Error> {
        let http = reqwest::Client::builder()
            .timeout(std::time::Duration::from_secs(15))
            .connect_timeout(std::time::Duration::from_secs(5))
            .redirect(reqwest::redirect::Policy::none())
            .build()?;
        Ok(Self {
            http,
            google_token: Arc::new(Mutex::new(None)),
        })
    }
}

/// Maps a provider call failure to the response the client should see.
pub fn provider_unavailable(detail: impl Into<String>) -> ApiError {
    ApiError::new(
        axum::http::StatusCode::SERVICE_UNAVAILABLE,
        "service_unavailable",
        detail,
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone;

    fn at(day: u32) -> DateTime<Utc> {
        Utc.with_ymd_and_hms(2026, 1, day, 0, 0, 0).unwrap()
    }

    #[test]
    fn active_subscription_grants_write_access_until_paid_through() {
        let now = at(10);
        let entitlement = compute_entitlement(&[(SubState::Active, Some(at(20)))], now);
        assert_eq!(entitlement.state, "active");
        assert!(entitlement.can_write);
        assert_eq!(entitlement.effective_expires_at, Some(at(20)));
        assert_eq!(
            entitlement.read_access_until,
            Some(at(20) + ChronoDuration::days(READ_WINDOW_DAYS))
        );
    }

    #[test]
    fn payment_retry_keeps_access_only_until_paid_through() {
        let entitlement = compute_entitlement(&[(SubState::PaymentRetry, Some(at(20)))], at(10));
        assert_eq!(entitlement.state, "grace");
        assert!(entitlement.can_write);

        let after = compute_entitlement(&[(SubState::PaymentRetry, Some(at(20)))], at(21));
        assert_eq!(after.state, "expired");
        assert!(!after.can_write);
    }

    #[test]
    fn expired_subscription_keeps_the_read_window_and_no_writes() {
        let entitlement = compute_entitlement(&[(SubState::Expired, Some(at(5)))], at(10));
        assert_eq!(entitlement.state, "expired");
        assert!(!entitlement.can_write);
        assert_eq!(
            entitlement.read_access_until,
            Some(at(5) + ChronoDuration::days(READ_WINDOW_DAYS))
        );
    }

    #[test]
    fn revoked_subscription_has_no_access_or_read_window() {
        let entitlement = compute_entitlement(&[(SubState::Revoked, Some(at(9)))], at(10));
        assert_eq!(entitlement.state, "revoked");
        assert!(!entitlement.can_write);
        assert_eq!(entitlement.read_access_until, None);
    }

    #[test]
    fn a_renewal_elsewhere_overrides_an_expired_one() {
        let entitlement = compute_entitlement(
            &[
                (SubState::Expired, Some(at(5))),
                (SubState::Active, Some(at(30))),
            ],
            at(10),
        );
        assert_eq!(entitlement.state, "active");
        assert_eq!(entitlement.effective_expires_at, Some(at(30)));
    }

    #[test]
    fn open_ended_grant_has_no_expiry_or_read_deadline() {
        let entitlement = compute_entitlement(&[(SubState::Active, None)], at(10));
        assert!(entitlement.can_write);
        assert_eq!(entitlement.effective_expires_at, None);
        assert_eq!(entitlement.read_access_until, None);
    }

    #[test]
    fn no_subscriptions_means_no_entitlement() {
        let entitlement = compute_entitlement(&[], at(10));
        assert_eq!(entitlement.state, "none");
        assert!(!entitlement.can_write);
    }

    #[test]
    fn pending_and_paused_never_grant_access() {
        assert!(!SubState::Pending.grants_access(None, at(10)));
        assert!(!SubState::Paused.grants_access(None, at(10)));
    }
}
