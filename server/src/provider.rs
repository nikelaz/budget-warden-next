use std::{
    collections::HashMap,
    sync::Arc,
    time::{Duration, Instant},
};

use jsonwebtoken::{
    Algorithm, DecodingKey, EncodingKey, Header, Validation, decode, decode_header, encode,
    jwk::JwkSet,
};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::Digest;
use tokio::sync::Mutex;

use crate::config::ProviderConfig;

const GOOGLE_ISSUERS: &[&str] = &["https://accounts.google.com", "accounts.google.com"];
const APPLE_ISSUERS: &[&str] = &["https://appleid.apple.com"];
const GOOGLE_JWKS_URL: &str = "https://www.googleapis.com/oauth2/v3/certs";
const APPLE_JWKS_URL: &str = "https://appleid.apple.com/auth/keys";
const GOOGLE_TOKEN_URL: &str = "https://oauth2.googleapis.com/token";
const APPLE_TOKEN_URL: &str = "https://appleid.apple.com/auth/token";

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub enum ProviderName {
    Google,
    Apple,
}

impl ProviderName {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Google => "google",
            Self::Apple => "apple",
        }
    }

    pub fn parse(value: &str) -> Option<Self> {
        match value {
            "google" => Some(Self::Google),
            "apple" => Some(Self::Apple),
            _ => None,
        }
    }

    fn jwks_url(self) -> &'static str {
        match self {
            Self::Google => GOOGLE_JWKS_URL,
            Self::Apple => APPLE_JWKS_URL,
        }
    }

    fn issuers(self) -> &'static [&'static str] {
        match self {
            Self::Google => GOOGLE_ISSUERS,
            Self::Apple => APPLE_ISSUERS,
        }
    }

    fn token_url(self) -> &'static str {
        match self {
            Self::Google => GOOGLE_TOKEN_URL,
            Self::Apple => APPLE_TOKEN_URL,
        }
    }
}

#[derive(Clone, Debug)]
pub struct ProviderIdentity {
    pub subject: String,
    pub display_email: Option<String>,
}

#[derive(Debug)]
pub enum ProviderError {
    InvalidProof,
    Unavailable,
}

#[derive(Clone)]
pub struct ProviderVerifier {
    client: reqwest::Client,
    key_sets: Arc<Mutex<HashMap<ProviderName, CachedKeySet>>>,
}

#[derive(Clone)]
struct CachedKeySet {
    jwks: JwkSet,
    loaded_at: Instant,
}

impl ProviderVerifier {
    pub fn new() -> Result<Self, reqwest::Error> {
        let client = reqwest::Client::builder()
            .timeout(Duration::from_secs(10))
            .connect_timeout(Duration::from_secs(5))
            .redirect(reqwest::redirect::Policy::limited(3))
            .build()?;
        Ok(Self {
            client,
            key_sets: Arc::new(Mutex::new(HashMap::new())),
        })
    }

    pub async fn exchange_code(
        &self,
        provider: ProviderName,
        provider_config: &ProviderConfig,
        client_id: &str,
        redirect_uri: &str,
        code: &str,
        pkce_verifier: Option<&str>,
    ) -> Result<String, ProviderError> {
        let mut params = vec![
            ("client_id", client_id.to_string()),
            ("code", code.to_string()),
            ("grant_type", "authorization_code".to_string()),
            ("redirect_uri", redirect_uri.to_string()),
        ];
        if let Some(verifier) = pkce_verifier {
            params.push(("code_verifier", verifier.to_string()));
        }

        match provider {
            ProviderName::Google => {
                if let Some(secret) = provider_config.client_secret.as_deref() {
                    params.push(("client_secret", secret.to_string()));
                }
            }
            ProviderName::Apple => {
                let client_secret = apple_client_secret(provider_config, client_id)?;
                params.push(("client_secret", client_secret));
            }
        }

        let response = self
            .client
            .post(provider.token_url())
            .form(&params)
            .send()
            .await
            .map_err(|_| ProviderError::Unavailable)?;
        if response.status().is_server_error() || response.status().as_u16() == 429 {
            return Err(ProviderError::Unavailable);
        }
        if !response.status().is_success() {
            return Err(ProviderError::InvalidProof);
        }
        let bytes = bounded_response(response).await?;
        let token_response = serde_json::from_slice::<ProviderTokenResponse>(&bytes)
            .map_err(|_| ProviderError::Unavailable)?;
        token_response.id_token.ok_or(ProviderError::InvalidProof)
    }

    pub async fn verify_identity_token(
        &self,
        provider: ProviderName,
        identity_token: &str,
        expected_client_id: &str,
        expected_nonce: &str,
    ) -> Result<ProviderIdentity, ProviderError> {
        let header = decode_header(identity_token).map_err(|_| ProviderError::InvalidProof)?;
        if header.alg != Algorithm::RS256 {
            return Err(ProviderError::InvalidProof);
        }
        let key_id = header.kid.ok_or(ProviderError::InvalidProof)?;
        let mut jwk = self.key_set(provider, false).await?.find(&key_id).cloned();
        if jwk.is_none() {
            jwk = self.key_set(provider, true).await?.find(&key_id).cloned();
        }
        let jwk = jwk.ok_or(ProviderError::InvalidProof)?;
        let key = DecodingKey::from_jwk(&jwk).map_err(|_| ProviderError::InvalidProof)?;
        let mut validation = Validation::new(Algorithm::RS256);
        validation.set_required_spec_claims(&["exp", "iss", "aud", "sub"]);
        validation.set_issuer(provider.issuers());
        validation.set_audience(&[expected_client_id]);
        validation.leeway = 30;
        let claims = decode::<ProviderClaims>(identity_token, &key, &validation)
            .map_err(|_| ProviderError::InvalidProof)?
            .claims;
        let audience_count = match &claims.aud {
            Value::String(_) => 1,
            Value::Array(values) => values.len(),
            _ => 0,
        };
        if claims
            .azp
            .as_deref()
            .is_some_and(|azp| azp != expected_client_id)
            || (audience_count > 1 && claims.azp.as_deref() != Some(expected_client_id))
        {
            return Err(ProviderError::InvalidProof);
        }
        let apple_nonce_hash = hex_digest(expected_nonce.as_bytes());
        let nonce_matches = claims.nonce.as_deref() == Some(expected_nonce)
            || (provider == ProviderName::Apple
                && claims.nonce.as_deref() == Some(apple_nonce_hash.as_str()));
        if !nonce_matches || claims.sub.is_empty() || claims.sub.len() > 255 {
            return Err(ProviderError::InvalidProof);
        }

        let display_email = if claims.email_verified() {
            claims.email
        } else {
            None
        };
        Ok(ProviderIdentity {
            subject: claims.sub,
            display_email,
        })
    }

    /// Verifies an RS256 JWT issued by the provider's published key set and
    /// returns its claims. Used for Pub/Sub push tokens and Sign in with Apple
    /// server-to-server notifications, which carry no per-request nonce.
    pub async fn verify_signed_jwt(
        &self,
        provider: ProviderName,
        token: &str,
        expected_audience: &str,
    ) -> Result<Value, ProviderError> {
        let header = decode_header(token).map_err(|_| ProviderError::InvalidProof)?;
        if header.alg != Algorithm::RS256 {
            return Err(ProviderError::InvalidProof);
        }
        let key_id = header.kid.ok_or(ProviderError::InvalidProof)?;
        let mut jwk = self.key_set(provider, false).await?.find(&key_id).cloned();
        if jwk.is_none() {
            jwk = self.key_set(provider, true).await?.find(&key_id).cloned();
        }
        let jwk = jwk.ok_or(ProviderError::InvalidProof)?;
        let key = DecodingKey::from_jwk(&jwk).map_err(|_| ProviderError::InvalidProof)?;
        let mut validation = Validation::new(Algorithm::RS256);
        validation.set_required_spec_claims(&["exp", "iss", "aud"]);
        validation.set_issuer(provider.issuers());
        validation.set_audience(&[expected_audience]);
        validation.leeway = 30;
        decode::<Value>(token, &key, &validation)
            .map(|data| data.claims)
            .map_err(|_| ProviderError::InvalidProof)
    }

    async fn key_set(
        &self,
        provider: ProviderName,
        force_refresh: bool,
    ) -> Result<JwkSet, ProviderError> {
        let mut key_sets = self.key_sets.lock().await;
        if !force_refresh {
            if let Some(cached) = key_sets.get(&provider)
                && cached.loaded_at.elapsed() < Duration::from_secs(60 * 60)
            {
                return Ok(cached.jwks.clone());
            }
        }

        let response = self
            .client
            .get(provider.jwks_url())
            .send()
            .await
            .map_err(|_| ProviderError::Unavailable)?;
        if !response.status().is_success()
            || response
                .content_length()
                .is_some_and(|size| size > 1024 * 1024)
        {
            return Err(ProviderError::Unavailable);
        }
        let bytes = bounded_response(response).await?;
        let jwks: JwkSet =
            serde_json::from_slice(&bytes).map_err(|_| ProviderError::Unavailable)?;
        key_sets.insert(
            provider,
            CachedKeySet {
                jwks: jwks.clone(),
                loaded_at: Instant::now(),
            },
        );
        Ok(jwks)
    }
}

fn hex_digest(bytes: &[u8]) -> String {
    use std::fmt::Write;
    let digest = sha2::Sha256::digest(bytes);
    let mut encoded = String::with_capacity(digest.len() * 2);
    for byte in digest {
        let _ = write!(encoded, "{byte:02x}");
    }
    encoded
}

#[derive(Deserialize)]
struct ProviderTokenResponse {
    id_token: Option<String>,
}

#[derive(Deserialize)]
struct ProviderClaims {
    sub: String,
    aud: Value,
    azp: Option<String>,
    email: Option<String>,
    email_verified: Option<Value>,
    nonce: Option<String>,
}

impl ProviderClaims {
    fn email_verified(&self) -> bool {
        match &self.email_verified {
            Some(Value::Bool(value)) => *value,
            Some(Value::String(value)) => value == "true",
            _ => false,
        }
    }
}

fn apple_client_secret(
    provider_config: &ProviderConfig,
    client_id: &str,
) -> Result<String, ProviderError> {
    let (Some(team_id), Some(key_id), Some(private_key)) = (
        provider_config.team_id.as_deref(),
        provider_config.key_id.as_deref(),
        provider_config.private_key.as_deref(),
    ) else {
        return Err(ProviderError::Unavailable);
    };
    let now = chrono::Utc::now().timestamp();
    let claims = AppleClientSecretClaims {
        iss: team_id,
        iat: now,
        exp: now + 5 * 60,
        aud: "https://appleid.apple.com",
        sub: client_id,
    };
    let key =
        EncodingKey::from_ec_pem(private_key.as_bytes()).map_err(|_| ProviderError::Unavailable)?;
    let mut header = Header::new(Algorithm::ES256);
    header.kid = Some(key_id.to_string());
    encode(&header, &claims, &key).map_err(|_| ProviderError::Unavailable)
}

#[derive(Serialize)]
struct AppleClientSecretClaims<'a> {
    iss: &'a str,
    iat: i64,
    exp: i64,
    aud: &'a str,
    sub: &'a str,
}

async fn bounded_response(mut response: reqwest::Response) -> Result<Vec<u8>, ProviderError> {
    const LIMIT: usize = 1024 * 1024;
    if response
        .content_length()
        .is_some_and(|size| size > LIMIT as u64)
    {
        return Err(ProviderError::Unavailable);
    }
    let mut bytes = Vec::new();
    while let Some(chunk) = response
        .chunk()
        .await
        .map_err(|_| ProviderError::Unavailable)?
    {
        if chunk.len() > LIMIT - bytes.len() {
            return Err(ProviderError::Unavailable);
        }
        bytes.extend_from_slice(&chunk);
    }
    Ok(bytes)
}
