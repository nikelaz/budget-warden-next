use sqlx::PgPool;

use crate::config::Config;
use crate::provider::ProviderVerifier;

#[derive(Clone)]
pub struct AppState {
    pub db: PgPool,
    pub config: Config,
    pub provider_verifier: ProviderVerifier,
}
