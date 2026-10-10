use sqlx::{PgPool, postgres::PgPoolOptions};
use uuid::Uuid;

use crate::config::Config;

static MIGRATOR: sqlx::migrate::Migrator = sqlx::migrate!("./migrations");

pub async fn connect(config: &Config) -> Result<PgPool, sqlx::Error> {
    let pool = PgPoolOptions::new()
        .max_connections(20)
        .acquire_timeout(std::time::Duration::from_secs(10))
        .connect(&config.database_url)
        .await?;
    MIGRATOR
        .run(&pool)
        .await
        .map_err(|error| sqlx::Error::Migrate(Box::new(error)))?;

    if let Some(account_id) = config.dev_account_id {
        seed_development_account(&pool, account_id, config.dev_entitlement).await?;
    }
    Ok(pool)
}

async fn seed_development_account(
    pool: &PgPool,
    account_id: Uuid,
    dev_entitlement: bool,
) -> Result<(), sqlx::Error> {
    sqlx::query("INSERT INTO accounts (id) VALUES ($1) ON CONFLICT (id) DO NOTHING")
        .bind(account_id)
        .execute(pool)
        .await?;

    if dev_entitlement {
        sqlx::query(
            "INSERT INTO entitlements (account_id, state, can_write, effective_expires_at, read_access_until) \
             VALUES ($1, 'active', true, '9999-12-31T23:59:59Z', '9999-12-31T23:59:59Z') \
             ON CONFLICT (account_id) DO UPDATE SET state = 'active', can_write = true, \
             effective_expires_at = EXCLUDED.effective_expires_at, read_access_until = EXCLUDED.read_access_until, updated_at = now()",
        )
        .bind(account_id)
        .execute(pool)
        .await?;
    } else {
        // Revoke only the synthetic grant created above, preserving real
        // entitlements when development authentication is used alongside them.
        sqlx::query(
            "UPDATE entitlements SET state = 'expired', can_write = false, \
             effective_expires_at = now(), read_access_until = now() + interval '90 days', updated_at = now() \
             WHERE account_id = $1 AND effective_expires_at = '9999-12-31T23:59:59Z'",
        )
        .bind(account_id)
        .execute(pool)
        .await?;
    }
    Ok(())
}
