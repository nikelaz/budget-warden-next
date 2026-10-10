use std::time::Duration;

use sqlx::PgPool;
use tokio::sync::watch;

use crate::config::{ACCOUNT_DELETION_GRACE_DAYS, Config};

pub async fn run_retention_worker(
    pool: PgPool,
    config: Config,
    mut shutdown: watch::Receiver<bool>,
) {
    let mut interval = tokio::time::interval(Duration::from_secs(15 * 60));
    interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    loop {
        tokio::select! {
            changed = shutdown.changed() => {
                if changed.is_err() || *shutdown.borrow() {
                    break;
                }
            }
            _ = interval.tick() => {
                if let Err(error) = prune_retained_rows(&pool, &config).await {
                    tracing::error!(error = %error, "cloud retention maintenance failed");
                }
            }
        }
    }
}

async fn prune_retained_rows(pool: &PgPool, config: &Config) -> Result<(), sqlx::Error> {
    let accounts = sqlx::query_scalar::<_, uuid::Uuid>("SELECT id FROM accounts ORDER BY id")
        .fetch_all(pool)
        .await?;

    for account_id in accounts {
        if let Err(error) = prune_account(pool, config, account_id).await {
            // One failed account must not prevent other scheduled purges.
            tracing::error!(%account_id, error = %error, "account retention maintenance failed; will retry");
        }
    }
    sqlx::query(
        "DELETE FROM auth_challenges WHERE expires_at < clock_timestamp() - interval '1 day'",
    )
    .execute(pool)
    .await?;
    sqlx::query("DELETE FROM reauthentication_proofs WHERE expires_at < clock_timestamp() OR consumed_at < clock_timestamp() - interval '1 day'")
        .execute(pool)
        .await?;
    sqlx::query("DELETE FROM session_refresh_tokens WHERE expires_at < clock_timestamp()")
        .execute(pool)
        .await?;
    sqlx::query("DELETE FROM sessions WHERE refresh_expires_at < clock_timestamp()")
        .execute(pool)
        .await?;
    Ok(())
}

async fn prune_account(
    pool: &PgPool,
    config: &Config,
    account_id: uuid::Uuid,
) -> Result<(), sqlx::Error> {
    let mut tx = pool.begin().await?;
    let exists =
        sqlx::query_scalar::<_, uuid::Uuid>("SELECT id FROM accounts WHERE id = $1 FOR UPDATE")
            .bind(account_id)
            .fetch_optional(&mut *tx)
            .await?;
    if exists.is_none() {
        tx.rollback().await?;
        return Ok(());
    }

    expire_retained_budgets(&mut tx, account_id).await?;

    let deletion =
        sqlx::query_as::<
            _,
            (
                Option<chrono::DateTime<chrono::Utc>>,
                Option<chrono::DateTime<chrono::Utc>>,
                bool,
            ),
        >("SELECT deleted_at, deletion_purge_at, deletion_data_purged_at IS NULL FROM accounts WHERE id = $1 FOR UPDATE")
        .bind(account_id)
        .fetch_optional(&mut *tx)
        .await?;
    if let Some((Some(deleted_at), deletion_purge_at, data_not_purged)) = deletion {
        let purge_after = deletion_purge_at
            .unwrap_or_else(|| deleted_at + chrono::Duration::days(ACCOUNT_DELETION_GRACE_DAYS));
        let database_now: chrono::DateTime<chrono::Utc> =
            sqlx::query_scalar("SELECT clock_timestamp()")
                .fetch_one(&mut *tx)
                .await?;
        if data_not_purged && database_now >= deleted_at + chrono::Duration::days(30) {
            tracing::error!(%account_id, %purge_after, "account deletion exceeded the 30-day deadline");
        }
        // A paid subscription that is still auto-renewing must be canceled
        // at the provider before the account rows that link it are removed.
        let cancellation_pending = sqlx::query_scalar::<_, bool>(
            "SELECT EXISTS (SELECT 1 FROM subscriptions WHERE account_id = $1 \
             AND cancel_requested_at IS NOT NULL AND cancelled_at IS NULL)",
        )
        .bind(account_id)
        .fetch_one(&mut *tx)
        .await?;
        if purge_after <= database_now && cancellation_pending {
            tracing::error!(%account_id, "account purge waits for provider cancellation");
        } else if purge_after <= database_now {
            purge_deleted_account(&mut tx, account_id).await?;
            tx.commit().await?;
            return Ok(());
        }
    }

    sqlx::query(
        "DELETE FROM budget_versions WHERE account_id = $1 AND archived_at < \
         clock_timestamp() - ($2::double precision * interval '1 day')",
    )
    .bind(account_id)
    .bind(config.history_retention_days as f64)
    .execute(&mut *tx)
    .await?;
    sqlx::query(
        "DELETE FROM mutation_receipts WHERE account_id = $1 AND committed_at < \
         clock_timestamp() - ($2::double precision * interval '1 day')",
    )
    .bind(account_id)
    .bind(config.receipt_retention_days as f64)
    .execute(&mut *tx)
    .await?;
    sqlx::query(
        "WITH removed AS ( \
           DELETE FROM account_changes WHERE account_id = $1 AND changed_at < \
             clock_timestamp() - ($2::double precision * interval '1 day') \
           RETURNING sequence \
         ) \
         UPDATE accounts SET retained_change_floor = GREATEST( \
           retained_change_floor, COALESCE((SELECT MAX(sequence) FROM removed), retained_change_floor) \
         ) WHERE id = $1",
    )
    .bind(account_id)
    .bind(config.feed_retention_days as f64)
    .execute(&mut *tx)
    .await?;
    tx.commit().await?;
    Ok(())
}

async fn purge_deleted_account(
    tx: &mut sqlx::Transaction<'_, sqlx::Postgres>,
    account_id: uuid::Uuid,
) -> Result<(), sqlx::Error> {
    sqlx::query(
        "DELETE FROM subscriptions WHERE account_id = $1 AND NOT (auto_renews OR \
         state IN ('pending', 'active', 'grace', 'payment_retry', 'paused') AND \
         (access_until IS NULL OR access_until > clock_timestamp()))",
    )
    .bind(account_id)
    .execute(&mut **tx)
    .await?;

    let has_active_billing_linkage = sqlx::query_scalar::<_, bool>(
        "SELECT EXISTS(SELECT 1 FROM subscriptions WHERE account_id = $1)",
    )
    .bind(account_id)
    .fetch_one(&mut **tx)
    .await?;

    sqlx::query("DELETE FROM budgets WHERE account_id = $1")
        .bind(account_id)
        .execute(&mut **tx)
        .await?;
    sqlx::query("DELETE FROM mutation_receipts WHERE account_id = $1")
        .bind(account_id)
        .execute(&mut **tx)
        .await?;
    sqlx::query("DELETE FROM auth_challenges WHERE account_id = $1")
        .bind(account_id)
        .execute(&mut **tx)
        .await?;
    sqlx::query("DELETE FROM reauthentication_proofs WHERE account_id = $1")
        .bind(account_id)
        .execute(&mut **tx)
        .await?;
    sqlx::query("DELETE FROM entitlements WHERE account_id = $1")
        .bind(account_id)
        .execute(&mut **tx)
        .await?;
    sqlx::query("DELETE FROM auth_identities WHERE account_id = $1")
        .bind(account_id)
        .execute(&mut **tx)
        .await?;
    sqlx::query("DELETE FROM devices WHERE account_id = $1")
        .bind(account_id)
        .execute(&mut **tx)
        .await?;

    if has_active_billing_linkage {
        // Keep only the account shell needed to associate late billing notifications.
        sqlx::query("UPDATE subscriptions SET management_url = NULL WHERE account_id = $1")
            .bind(account_id)
            .execute(&mut **tx)
            .await?;
        sqlx::query(
            "UPDATE accounts SET next_change_seq = 0, retained_change_floor = 0, \
             deletion_data_purged_at = COALESCE(deletion_data_purged_at, clock_timestamp()) WHERE id = $1",
        )
        .bind(account_id)
        .execute(&mut **tx)
        .await?;
    } else {
        sqlx::query("DELETE FROM accounts WHERE id = $1")
            .bind(account_id)
            .execute(&mut **tx)
            .await?;
    }
    Ok(())
}

async fn expire_retained_budgets(
    tx: &mut sqlx::Transaction<'_, sqlx::Postgres>,
    account_id: uuid::Uuid,
) -> Result<(), sqlx::Error> {
    let entitlement = sqlx::query_as::<_, (bool, bool)>(
        "SELECT \
           (state IN ('active', 'grace') AND (effective_expires_at IS NULL OR effective_expires_at > clock_timestamp())), \
           (read_access_until IS NOT NULL AND read_access_until <= clock_timestamp()) \
         FROM entitlements WHERE account_id = $1 FOR UPDATE",
    )
    .bind(account_id)
    .fetch_optional(&mut **tx)
    .await?;
    let Some((has_current_access, read_window_ended)) = entitlement else {
        return Ok(());
    };
    if !read_window_ended || has_current_access {
        return Ok(());
    }
    purge_live_budgets(tx, account_id).await
}

/// Ends every live cloud budget as `retention_expired`. Used when the read
/// window has passed, including before a renewal restores access.
pub(crate) async fn purge_live_budgets(
    tx: &mut sqlx::Transaction<'_, sqlx::Postgres>,
    account_id: uuid::Uuid,
) -> Result<(), sqlx::Error> {
    let cloud_budget_ids = sqlx::query_scalar::<_, uuid::Uuid>(
        "SELECT cloud_budget_id FROM budgets WHERE account_id = $1 AND deleted_at IS NULL FOR UPDATE",
    )
    .bind(account_id)
    .fetch_all(&mut **tx)
    .await?;
    for cloud_budget_id in cloud_budget_ids {
        let deleted_at: chrono::DateTime<chrono::Utc> =
            sqlx::query_scalar("SELECT clock_timestamp()")
                .fetch_one(&mut **tx)
                .await?;
        let sequence = sqlx::query_scalar::<_, i64>(
            "UPDATE accounts SET next_change_seq = next_change_seq + 1 WHERE id = $1 RETURNING next_change_seq",
        )
        .bind(account_id)
        .fetch_one(&mut **tx)
        .await?;
        sqlx::query(
            "UPDATE budgets SET snapshot_json = NULL, current_bytes = 0, deleted_at = $3, \
             deletion_reason = 'retention_expired', updated_at = $3, server_version = $4 \
             WHERE account_id = $1 AND cloud_budget_id = $2",
        )
        .bind(account_id)
        .bind(cloud_budget_id)
        .bind(deleted_at)
        .bind(uuid::Uuid::new_v4().to_string())
        .execute(&mut **tx)
        .await?;
        sqlx::query("DELETE FROM budget_versions WHERE account_id = $1 AND cloud_budget_id = $2")
            .bind(account_id)
            .bind(cloud_budget_id)
            .execute(&mut **tx)
            .await?;
        sqlx::query(
            "INSERT INTO account_changes (account_id, sequence, cloud_budget_id, kind, changed_at, deletion_reason) \
             VALUES ($1, $2, $3, 'deleted', $4, 'retention_expired')",
        )
        .bind(account_id)
        .bind(sequence)
        .bind(cloud_budget_id)
        .bind(deleted_at)
        .execute(&mut **tx)
        .await?;
    }
    Ok(())
}
