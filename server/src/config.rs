use std::{collections::HashMap, env, net::SocketAddr};

use sha2::{Digest, Sha256};
use uuid::Uuid;

// Leave a day for maintenance retries before the published 30-day maximum.
pub const ACCOUNT_DELETION_GRACE_DAYS: i64 = 29;

#[derive(Clone)]
pub struct Config {
    pub environment: String,
    pub listen_addr: SocketAddr,
    pub database_url: String,
    pub cursor_secret: Vec<u8>,
    pub max_snapshot_bytes: usize,
    pub max_request_body_bytes: usize,
    pub account_storage_limit_bytes: i64,
    pub catalog_page_size: usize,
    pub change_page_size: usize,
    pub feed_retention_days: i64,
    pub receipt_retention_days: i64,
    pub history_retention_days: i64,
    pub history_versions_per_budget: i64,
    pub minimum_client_version: String,
    pub dev_account_id: Option<Uuid>,
    pub dev_bearer_token_hash: Option<[u8; 32]>,
    pub dev_entitlement: bool,
    pub google_auth: ProviderConfig,
    pub apple_auth: ProviderConfig,
}

#[derive(Clone, Default)]
pub struct ProviderConfig {
    pub client_ids: HashMap<String, String>,
    pub redirect_uris: Vec<String>,
    pub client_secret: Option<String>,
    pub team_id: Option<String>,
    pub key_id: Option<String>,
    pub private_key: Option<String>,
}

impl ProviderConfig {
    pub fn client_id(&self, platform: &str) -> Option<&str> {
        self.client_ids.get(platform).map(String::as_str)
    }
}

impl Config {
    pub fn from_env() -> Result<Self, String> {
        let environment = env::var("BW_ENV").unwrap_or_else(|_| "production".to_string());
        let is_development = environment == "development";
        if environment != "development" && environment != "staging" && environment != "production" {
            return Err("BW_ENV must be development, staging, or production".to_string());
        }

        let database_url = required("BW_DATABASE_URL")?;
        let cursor_secret = match env::var("BW_CURSOR_SECRET") {
            Ok(secret) if secret.len() >= 32 => secret.into_bytes(),
            Ok(_) => return Err("BW_CURSOR_SECRET must contain at least 32 bytes".to_string()),
            Err(_) if is_development => b"local-development-only-cloud-cursor-secret".to_vec(),
            Err(_) => return Err("BW_CURSOR_SECRET is required outside development".to_string()),
        };

        let dev_account = env::var("BW_DEV_ACCOUNT_ID").ok();
        let dev_token = env::var("BW_DEV_BEARER_TOKEN").ok();
        let dev_entitlement = parse_bool("BW_DEV_ENTITLEMENT", false)?;
        if !is_development
            && (dev_account.is_some()
                || dev_token.is_some()
                || env::var_os("BW_DEV_ENTITLEMENT").is_some())
        {
            return Err("BW_DEV_* settings are allowed only when BW_ENV=development".to_string());
        }
        let dev_account_id = if is_development {
            Some(match dev_account {
                Some(value) => Uuid::parse_str(&value)
                    .map_err(|_| "BW_DEV_ACCOUNT_ID must be a UUID".to_string())?,
                None => Uuid::from_u128(1),
            })
        } else {
            None
        };
        let dev_bearer_token_hash = dev_token
            .map(|token| {
                if token.len() < 24 {
                    return Err("BW_DEV_BEARER_TOKEN must contain at least 24 bytes".to_string());
                }
                Ok(<[u8; 32]>::from(Sha256::digest(token.as_bytes())))
            })
            .transpose()?;

        let google_auth = provider_config("GOOGLE", false)?;
        let apple_auth = provider_config("APPLE", true)?;

        let max_snapshot_bytes = parse_usize("BW_MAX_SNAPSHOT_BYTES", 10 * 1024 * 1024)?;
        let request_limit_default = max_snapshot_bytes
            .checked_add(64 * 1024)
            .ok_or_else(|| "Configured snapshot limit overflows the request limit".to_string())?;
        let max_request_body_bytes =
            parse_usize("BW_MAX_REQUEST_BODY_BYTES", request_limit_default)?;
        if max_request_body_bytes < request_limit_default {
            return Err(
                "BW_MAX_REQUEST_BODY_BYTES must allow the snapshot limit plus the 64 KiB API envelope"
                    .to_string(),
            );
        }
        if max_snapshot_bytes == 0 {
            return Err("BW_MAX_SNAPSHOT_BYTES must be greater than zero".to_string());
        }
        let account_storage_limit_bytes =
            parse_i64("BW_ACCOUNT_STORAGE_LIMIT_BYTES", 5 * 1024 * 1024 * 1024)?;
        let feed_retention_days = parse_i64("BW_FEED_RETENTION_DAYS", 90)?;
        let receipt_retention_days = parse_i64("BW_RECEIPT_RETENTION_DAYS", 400)?;
        let history_retention_days = parse_i64("BW_HISTORY_RETENTION_DAYS", 30)?;
        let history_versions_per_budget = parse_i64("BW_HISTORY_VERSIONS_PER_BUDGET", 2)?;
        if account_storage_limit_bytes <= 0
            || feed_retention_days < 90
            || receipt_retention_days < 400
            || !(1..=30).contains(&history_retention_days)
            || !(0..=2).contains(&history_versions_per_budget)
        {
            return Err("Storage limit must be positive; feed retention must be at least 90 days; receipt retention at least 400 days; history retention between 1 and 30 days; history versions between zero and two".to_string());
        }

        Ok(Self {
            environment,
            listen_addr: env::var("BW_LISTEN_ADDR")
                .unwrap_or_else(|_| "0.0.0.0:8080".to_string())
                .parse()
                .map_err(|_| "BW_LISTEN_ADDR must be a socket address".to_string())?,
            database_url,
            cursor_secret,
            max_snapshot_bytes,
            max_request_body_bytes,
            account_storage_limit_bytes,
            catalog_page_size: parse_usize("BW_CATALOG_PAGE_SIZE", 50)?.clamp(1, 100),
            change_page_size: parse_usize("BW_CHANGE_PAGE_SIZE", 50)?.clamp(1, 100),
            feed_retention_days,
            receipt_retention_days,
            history_retention_days,
            history_versions_per_budget,
            minimum_client_version: env::var("BW_MINIMUM_CLIENT_VERSION")
                .unwrap_or_else(|_| "0.1.0".to_string()),
            dev_account_id,
            dev_bearer_token_hash,
            dev_entitlement,
            google_auth,
            apple_auth,
        })
    }
}

fn provider_config(prefix: &str, apple: bool) -> Result<ProviderConfig, String> {
    let mut client_ids = HashMap::new();
    for (platform, suffix) in [
        ("macos", "MACOS"),
        ("ios", "IOS"),
        ("android", "ANDROID"),
        ("windows", "WINDOWS"),
        ("web", "WEB"),
    ] {
        if let Ok(value) = env::var(format!("BW_{prefix}_CLIENT_ID_{suffix}")) {
            let value = value.trim().to_string();
            if !value.is_empty() {
                client_ids.insert(platform.to_string(), value);
            }
        }
    }

    let redirect_uris = env::var(format!("BW_{prefix}_REDIRECT_URIS"))
        .unwrap_or_default()
        .split(',')
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_string)
        .collect();
    let optional = |name: &str| {
        env::var(format!("BW_{prefix}_{name}"))
            .ok()
            .filter(|value| !value.trim().is_empty())
    };
    let settings = ProviderConfig {
        client_ids,
        redirect_uris,
        client_secret: optional("CLIENT_SECRET"),
        team_id: optional("TEAM_ID"),
        key_id: optional("KEY_ID"),
        private_key: optional("PRIVATE_KEY").map(|value| value.replace("\\n", "\n")),
    };

    if apple {
        let configured_apple_signing_fields = [
            settings.team_id.is_some(),
            settings.key_id.is_some(),
            settings.private_key.is_some(),
        ];
        if configured_apple_signing_fields.iter().any(|field| *field)
            && !configured_apple_signing_fields.iter().all(|field| *field)
        {
            return Err("BW_APPLE_TEAM_ID, BW_APPLE_KEY_ID, and BW_APPLE_PRIVATE_KEY must be configured together".to_string());
        }
    }

    Ok(settings)
}

fn required(name: &str) -> Result<String, String> {
    env::var(name).map_err(|_| format!("{name} is required"))
}

fn parse_bool(name: &str, default: bool) -> Result<bool, String> {
    match env::var(name) {
        Ok(value) => match value.to_ascii_lowercase().as_str() {
            "true" | "1" | "yes" => Ok(true),
            "false" | "0" | "no" => Ok(false),
            _ => Err(format!("{name} must be true or false")),
        },
        Err(_) => Ok(default),
    }
}

fn parse_usize(name: &str, default: usize) -> Result<usize, String> {
    match env::var(name) {
        Ok(value) => value
            .parse()
            .map_err(|_| format!("{name} must be a nonnegative integer")),
        Err(_) => Ok(default),
    }
}

fn parse_i64(name: &str, default: i64) -> Result<i64, String> {
    match env::var(name) {
        Ok(value) => value
            .parse()
            .map_err(|_| format!("{name} must be a signed 64-bit integer")),
        Err(_) => Ok(default),
    }
}
