use axum::{
    Extension, Json, Router,
    extract::{Path, State, rejection::JsonRejection},
    http::{HeaderMap, HeaderValue, StatusCode},
    middleware,
    response::IntoResponse,
    routing::{delete, get, post},
};
use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use chrono::{DateTime, Duration as ChronoDuration, Utc};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use sqlx::{FromRow, Postgres, Transaction};
use subtle::ConstantTimeEq;
use url::Url;
use uuid::Uuid;

use crate::{
    auth::{self, AuthenticatedAccount, AuthenticatedSession},
    config::{ACCOUNT_DELETION_GRACE_DAYS, Config, ProviderConfig},
    errors::{ApiError, ApiResult, RequestContext, database_error, invalid_request},
    provider::{ProviderError, ProviderIdentity, ProviderName},
    state::AppState,
    tokens::digest,
};

const ACCESS_TOKEN_MINUTES: i64 = 15;
const REFRESH_TOKEN_DAYS: i64 = 60;
const CHALLENGE_MINUTES: i64 = 5;
const PROOF_MINUTES: i64 = 5;

pub fn routes(state: AppState) -> Router<AppState> {
    let protected = middleware::from_fn_with_state(state.clone(), auth::require_auth);
    Router::new()
        .route(
            "/v1/auth/{provider}/start",
            post(start_authentication),
        )
        .route(
            "/v1/auth/{provider}/complete",
            post(complete_authentication),
        )
        .route(
            "/v1/sessions/refresh",
            post(refresh_session),
        )
        .route(
            "/v1/sessions/revoke",
            post(revoke_session).route_layer(protected.clone()),
        )
        .route(
            "/v1/me",
            get(current_account).route_layer(protected.clone()),
        )
        .route(
            "/v1/entitlement",
            get(current_entitlement).route_layer(protected.clone()),
        )
        .route(
            "/v1/account/identities/link",
            post(link_identity).route_layer(protected.clone()),
        )
        .route("/v1/account", delete(delete_account).route_layer(protected))
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct AuthStartRequest {
    purpose: String,
    platform: String,
    flow: String,
    redirect_uri: Option<String>,
    device_id: Uuid,
    pkce_challenge: Option<String>,
    pkce_method: Option<String>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct AuthCompleteRequest {
    challenge_id: Uuid,
    state: String,
    authorization_code: Option<String>,
    pkce_verifier: Option<String>,
    identity_token: Option<String>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct LinkIdentityRequest {
    provider: String,
    challenge_id: Uuid,
    state: String,
    authorization_code: Option<String>,
    pkce_verifier: Option<String>,
    identity_token: Option<String>,
}

#[derive(Deserialize, Default)]
#[serde(deny_unknown_fields)]
#[serde(default)]
struct RevokeRequest {
    revoke_all_sessions: bool,
}

#[derive(Serialize)]
struct AuthChallengeResponse {
    challenge_id: Uuid,
    state: String,
    nonce: String,
    expires_at: DateTime<Utc>,
    authorization_url: Option<String>,
    credential_mode: &'static str,
    pkce_required: bool,
}

#[derive(Serialize)]
struct AuthCompleteResponse {
    purpose: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    account: Option<AccountResponse>,
    #[serde(skip_serializing_if = "Option::is_none")]
    tokens: Option<SessionTokens>,
    #[serde(skip_serializing_if = "Option::is_none")]
    reauthentication_token: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    expires_at: Option<DateTime<Utc>>,
}

#[derive(Serialize)]
struct AccountResponse {
    account_id: Uuid,
    identities: Vec<AccountIdentity>,
    created_at: DateTime<Utc>,
}

#[derive(Serialize, FromRow)]
struct AccountIdentity {
    provider: String,
    display_email: Option<String>,
    linked_at: DateTime<Utc>,
}

#[derive(Serialize)]
struct SessionTokens {
    account_id: Uuid,
    session_id: Uuid,
    access_token: String,
    access_expires_at: DateTime<Utc>,
    refresh_token: String,
}

#[derive(Serialize)]
struct EntitlementResponse {
    plan_id: Option<&'static str>,
    state: String,
    can_create: bool,
    can_write: bool,
    can_read: bool,
    storage: StorageUsage,
    subscriptions: Vec<SubscriptionResponse>,
    effective_expires_at: Option<DateTime<Utc>>,
    read_access_until: Option<DateTime<Utc>>,
}

#[derive(Serialize)]
struct StorageUsage {
    used_bytes: i64,
    limit_bytes: i64,
}

#[derive(Serialize, FromRow)]
struct SubscriptionResponse {
    subscription_id: Uuid,
    billing_provider: String,
    state: String,
    access_until: Option<DateTime<Utc>>,
    auto_renews: bool,
    management_url: Option<String>,
}

#[derive(FromRow, Clone)]
struct ChallengeRow {
    id: Uuid,
    provider: String,
    purpose: String,
    platform: String,
    flow: String,
    redirect_uri: Option<String>,
    client_id: String,
    state_hash: Vec<u8>,
    nonce: String,
    device_id: Uuid,
    pkce_challenge: Option<String>,
    account_id: Option<Uuid>,
    session_id: Option<Uuid>,
    expires_at: DateTime<Utc>,
    consumed_at: Option<DateTime<Utc>>,
}

#[derive(FromRow)]
struct AccountCreated {
    id: Uuid,
    created_at: DateTime<Utc>,
    deleted_at: Option<DateTime<Utc>>,
    deletion_purge_at: Option<DateTime<Utc>>,
}

#[derive(FromRow)]
struct RefreshTokenRow {
    session_id: Uuid,
    account_id: Uuid,
    device_id: Uuid,
    refresh_family_id: Uuid,
    expires_at: DateTime<Utc>,
    consumed_at: Option<DateTime<Utc>>,
    revoked_at: Option<DateTime<Utc>>,
    refresh_expires_at: DateTime<Utc>,
    account_deleted_at: Option<DateTime<Utc>>,
    account_deletion_purge_at: Option<DateTime<Utc>>,
}

#[derive(FromRow)]
struct EntitlementRow {
    state: String,
    can_write: bool,
    effective_expires_at: Option<DateTime<Utc>>,
    read_access_until: Option<DateTime<Utc>>,
}

#[derive(Serialize)]
struct DeletionSchedule {
    access_revoked_at: DateTime<Utc>,
    data_purge_after: DateTime<Utc>,
    backup_purge_by: DateTime<Utc>,
    store_subscription_management_urls: Vec<String>,
}

async fn start_authentication(
    State(state): State<AppState>,
    Path(provider): Path<String>,
    headers: HeaderMap,
    Extension(context): Extension<RequestContext>,
    body: Result<Json<AuthStartRequest>, JsonRejection>,
) -> axum::response::Response {
    let result = match body {
        Ok(Json(request)) => start_authentication_inner(state, provider, headers, request).await,
        Err(_) => Err(invalid_request(
            "Request body must be a valid authentication request.",
        )),
    };
    auth_response(result, context)
}

async fn start_authentication_inner(
    state: AppState,
    provider_path: String,
    headers: HeaderMap,
    request: AuthStartRequest,
) -> Result<Json<AuthChallengeResponse>, ApiError> {
    require_protocol(&headers)?;
    let provider = ProviderName::parse(&provider_path)
        .ok_or_else(|| invalid_request("Provider must be google or apple."))?;
    if !matches!(
        request.platform.as_str(),
        "macos" | "ios" | "android" | "windows" | "web"
    ) {
        return Err(invalid_request("Platform is not supported."));
    }
    if !matches!(
        request.purpose.as_str(),
        "sign_in" | "link_identity" | "reauthenticate" | "delete_account"
    ) {
        return Err(invalid_request("Authentication purpose is not supported."));
    }
    if !matches!(request.flow.as_str(), "native" | "browser") {
        return Err(invalid_request(
            "Authentication flow must be native or browser.",
        ));
    }
    if request
        .pkce_method
        .as_deref()
        .is_some_and(|method| method != "S256")
    {
        return Err(invalid_request("Only S256 PKCE is supported."));
    }
    if request.pkce_challenge.is_some() != request.pkce_method.is_some() {
        return Err(invalid_request(
            "PKCE challenge and method must be supplied together.",
        ));
    }
    if request
        .pkce_challenge
        .as_deref()
        .is_some_and(|challenge| !valid_pkce_challenge(challenge))
    {
        return Err(invalid_request(
            "PKCE challenge must be an S256 base64url value.",
        ));
    }
    if request.flow == "native" && request.pkce_challenge.is_some() {
        return Err(invalid_request(
            "PKCE is supported only for browser authorization-code flows.",
        ));
    }
    if request.flow == "browser" && request.pkce_challenge.is_none() {
        return Err(invalid_request(
            "Browser authorization-code flows require S256 PKCE.",
        ));
    }

    let provider_config = provider_config(&state.config, provider);
    let client_id = provider_config
        .client_id(&request.platform)
        .ok_or_else(provider_unavailable)?
        .to_string();
    let (account_id, session_id) = if request.purpose == "sign_in" {
        (None, None)
    } else {
        let session = authenticated_session(&state, &headers).await?;
        let session_id = session
            .session_id
            .ok_or_else(|| unauthorized("A provider sign-in session is required."))?;
        let device_id =
            sqlx::query_scalar::<_, Uuid>("SELECT device_id FROM sessions WHERE id = $1")
                .bind(session_id)
                .fetch_optional(&state.db)
                .await
                .map_err(database_error)?;
        if device_id != Some(request.device_id) {
            return Err(invalid_request(
                "Device ID does not match the current session.",
            ));
        }
        if request.purpose == "link_identity" {
            let already_linked = sqlx::query_scalar::<_, bool>(
                "SELECT EXISTS(SELECT 1 FROM auth_identities WHERE account_id = $1 AND provider = $2)",
            )
            .bind(session.account_id)
            .bind(provider.as_str())
            .fetch_one(&state.db)
            .await
            .map_err(database_error)?;
            if already_linked {
                return Err(identity_already_linked());
            }
        }
        (Some(session.account_id), Some(session_id))
    };

    let redirect_uri = if request.flow == "browser" {
        let redirect_uri = request
            .redirect_uri
            .as_deref()
            .ok_or_else(|| invalid_request("Browser flow requires a redirect URI."))?;
        if !provider_config
            .redirect_uris
            .iter()
            .any(|allowed| allowed == redirect_uri)
        {
            return Err(invalid_request(
                "Redirect URI is not allowlisted for this provider.",
            ));
        }
        Some(redirect_uri.to_string())
    } else {
        if request.redirect_uri.is_some() {
            return Err(invalid_request(
                "Native flow does not accept a redirect URI.",
            ));
        }
        None
    };

    if provider == ProviderName::Apple
        && request.flow == "browser"
        && (provider_config.team_id.is_none()
            || provider_config.key_id.is_none()
            || provider_config.private_key.is_none())
    {
        return Err(provider_unavailable());
    }
    if provider == ProviderName::Google
        && request.platform == "web"
        && request.flow == "browser"
        && provider_config.client_secret.is_none()
    {
        return Err(provider_unavailable());
    }

    let challenge_id = Uuid::new_v4();
    let oauth_state = opaque_token();
    let nonce = opaque_token();
    let expires_at = Utc::now() + ChronoDuration::minutes(CHALLENGE_MINUTES);
    let authorization_url = if request.flow == "browser" {
        Some(authorization_url(
            provider,
            &client_id,
            redirect_uri.as_deref().expect("validated browser redirect"),
            &oauth_state,
            &nonce,
            request.pkce_challenge.as_deref(),
            matches!(
                request.purpose.as_str(),
                "reauthenticate" | "delete_account"
            ),
        )?)
    } else {
        None
    };

    sqlx::query(
        "INSERT INTO auth_challenges (id, provider, purpose, platform, flow, redirect_uri, client_id, state_hash, nonce, device_id, pkce_challenge, account_id, session_id, expires_at) \
         VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14)",
    )
    .bind(challenge_id)
    .bind(provider.as_str())
    .bind(&request.purpose)
    .bind(&request.platform)
    .bind(&request.flow)
    .bind(&redirect_uri)
    .bind(&client_id)
    .bind(digest(oauth_state.as_bytes()).to_vec())
    .bind(&nonce)
    .bind(request.device_id)
    .bind(&request.pkce_challenge)
    .bind(account_id)
    .bind(session_id)
    .bind(expires_at)
    .execute(&state.db)
    .await
    .map_err(database_error)?;

    Ok(Json(AuthChallengeResponse {
        challenge_id,
        state: oauth_state,
        nonce,
        expires_at,
        authorization_url,
        credential_mode: if request.flow == "native" {
            "identity_token"
        } else {
            "authorization_code"
        },
        pkce_required: request.pkce_challenge.is_some(),
    }))
}

async fn complete_authentication(
    State(state): State<AppState>,
    Path(provider): Path<String>,
    headers: HeaderMap,
    Extension(context): Extension<RequestContext>,
    body: Result<Json<AuthCompleteRequest>, JsonRejection>,
) -> axum::response::Response {
    let result = match body {
        Ok(Json(request)) => complete_authentication_inner(state, provider, headers, request).await,
        Err(_) => Err(invalid_request(
            "Request body must be a valid authentication request.",
        )),
    };
    auth_response(result, context)
}

async fn complete_authentication_inner(
    state: AppState,
    provider_path: String,
    headers: HeaderMap,
    request: AuthCompleteRequest,
) -> Result<Json<AuthCompleteResponse>, ApiError> {
    require_protocol(&headers)?;
    let provider = ProviderName::parse(&provider_path)
        .ok_or_else(|| invalid_request("Provider must be google or apple."))?;
    let (challenge, identity) = verify_challenge(
        &state,
        provider,
        request.challenge_id,
        &request.state,
        request.authorization_code.as_deref(),
        request.pkce_verifier.as_deref(),
        request.identity_token.as_deref(),
        false,
    )
    .await?;
    if challenge.purpose == "link_identity" {
        return Err(invalid_request(
            "Identity-link challenges must be completed through the identity-link endpoint.",
        ));
    }

    let completion_session = if challenge.purpose != "sign_in" {
        Some(authenticated_session(&state, &headers).await?)
    } else {
        None
    };
    let mut tx = state.db.begin().await.map_err(database_error)?;
    let locked = lock_live_challenge(&mut tx, &challenge, &request.state).await?;
    sqlx::query("UPDATE auth_challenges SET consumed_at = now() WHERE id = $1")
        .bind(locked.id)
        .execute(&mut *tx)
        .await
        .map_err(database_error)?;

    let response = match locked.purpose.as_str() {
        "sign_in" => {
            let (account, tokens) = sign_in(&mut tx, &locked, provider, identity).await?;
            AuthCompleteResponse {
                purpose: "sign_in".to_string(),
                account: Some(account),
                tokens: Some(tokens),
                reauthentication_token: None,
                expires_at: None,
            }
        }
        "reauthenticate" | "delete_account" => {
            let account_id = locked
                .account_id
                .ok_or_else(|| ApiError::internal("challenge has no account"))?;
            let session_id = locked
                .session_id
                .ok_or_else(|| ApiError::internal("challenge has no session"))?;
            let authenticated =
                completion_session.ok_or_else(|| unauthorized("Authentication is required."))?;
            if authenticated.account_id != account_id
                || authenticated.session_id != Some(session_id)
            {
                return Err(unauthorized(
                    "The authentication challenge belongs to another session.",
                ));
            }
            require_account_not_pending_deletion(&mut tx, account_id).await?;
            let session_active = sqlx::query_scalar::<_, bool>(
                "SELECT EXISTS(SELECT 1 FROM sessions WHERE id = $1 AND account_id = $2 AND revoked_at IS NULL AND access_expires_at > now())",
            )
            .bind(session_id)
            .bind(account_id)
            .fetch_one(&mut *tx)
            .await
            .map_err(database_error)?;
            if !session_active {
                return Err(unauthorized(
                    "The authentication session is no longer active.",
                ));
            }
            require_linked_identity(&mut tx, account_id, provider, &identity).await?;
            let proof = opaque_token();
            let proof_expiry = Utc::now() + ChronoDuration::minutes(PROOF_MINUTES);
            let proof_purpose = if locked.purpose == "delete_account" {
                "delete_account"
            } else {
                "link_identity"
            };
            sqlx::query(
                "INSERT INTO reauthentication_proofs (token_hash, account_id, session_id, purpose, expires_at) VALUES ($1, $2, $3, $4, $5)",
            )
            .bind(digest(proof.as_bytes()).to_vec())
            .bind(account_id)
            .bind(session_id)
            .bind(proof_purpose)
            .bind(proof_expiry)
            .execute(&mut *tx)
            .await
            .map_err(database_error)?;
            AuthCompleteResponse {
                purpose: locked.purpose,
                account: None,
                tokens: None,
                reauthentication_token: Some(proof),
                expires_at: Some(proof_expiry),
            }
        }
        _ => {
            return Err(invalid_request(
                "Authentication challenge purpose is not supported here.",
            ));
        }
    };

    tx.commit().await.map_err(database_error)?;
    Ok(Json(response))
}

async fn link_identity(
    State(state): State<AppState>,
    headers: HeaderMap,
    Extension(account): Extension<AuthenticatedAccount>,
    Extension(session): Extension<AuthenticatedSession>,
    Extension(context): Extension<RequestContext>,
    body: Result<Json<LinkIdentityRequest>, JsonRejection>,
) -> axum::response::Response {
    let result = match body {
        Ok(Json(request)) => link_identity_inner(state, headers, account, session, request).await,
        Err(_) => Err(invalid_request(
            "Request body must be a valid identity-link request.",
        )),
    };
    auth_response(result, context)
}

async fn link_identity_inner(
    state: AppState,
    headers: HeaderMap,
    account: AuthenticatedAccount,
    session: AuthenticatedSession,
    request: LinkIdentityRequest,
) -> Result<Json<AccountResponse>, ApiError> {
    require_protocol(&headers)?;
    let provider = ProviderName::parse(&request.provider)
        .ok_or_else(|| invalid_request("Provider must be google or apple."))?;
    let session_id = session
        .session_id
        .ok_or_else(|| unauthorized("A provider sign-in session is required."))?;
    let recent_auth = headers
        .get("X-Reauthentication-Token")
        .and_then(|value| value.to_str().ok())
        .filter(|value| !value.is_empty())
        .ok_or_else(|| {
            ApiError::new(
                StatusCode::FORBIDDEN,
                "reauthentication_required",
                "Reauthenticate before linking an identity.",
            )
        })?;
    let (challenge, identity) = verify_challenge(
        &state,
        provider,
        request.challenge_id,
        &request.state,
        request.authorization_code.as_deref(),
        request.pkce_verifier.as_deref(),
        request.identity_token.as_deref(),
        true,
    )
    .await?;
    if challenge.purpose != "link_identity"
        || challenge.account_id != Some(account.0)
        || challenge.session_id != Some(session_id)
    {
        return Err(ApiError::new(
            StatusCode::UNAUTHORIZED,
            "invalid_provider_proof",
            "The identity-link challenge is not bound to this session.",
        ));
    }

    let mut tx = state.db.begin().await.map_err(database_error)?;
    let locked = lock_live_challenge(&mut tx, &challenge, &request.state).await?;
    consume_reauthentication_proof(&mut tx, recent_auth, account.0, session_id, "link_identity")
        .await?;
    require_account_not_pending_deletion(&mut tx, account.0).await?;
    let result = sqlx::query(
        "INSERT INTO auth_identities (id, account_id, provider, issuer, subject, display_email) \
         VALUES ($1, $2, $3, $4, $5, $6) ON CONFLICT DO NOTHING",
    )
    .bind(Uuid::new_v4())
    .bind(account.0)
    .bind(provider.as_str())
    .bind(canonical_issuer(provider))
    .bind(&identity.subject)
    .bind(&identity.display_email)
    .execute(&mut *tx)
    .await
    .map_err(database_error)?;
    if result.rows_affected() == 0 {
        return Err(identity_already_linked());
    }
    sqlx::query("UPDATE auth_challenges SET consumed_at = now() WHERE id = $1")
        .bind(locked.id)
        .execute(&mut *tx)
        .await
        .map_err(database_error)?;
    let account_response = account_response(&mut tx, account.0).await?;
    tx.commit().await.map_err(database_error)?;
    Ok(Json(account_response))
}

async fn refresh_session(
    State(state): State<AppState>,
    headers: HeaderMap,
    Extension(context): Extension<RequestContext>,
    body: Result<Json<RefreshRequest>, JsonRejection>,
) -> axum::response::Response {
    let result = match body {
        Ok(Json(request)) => refresh_session_inner(state, headers, request).await,
        Err(_) => Err(invalid_request(
            "Request body must contain a refresh token.",
        )),
    };
    auth_response(result, context)
}

async fn refresh_session_inner(
    state: AppState,
    headers: HeaderMap,
    request: RefreshRequest,
) -> Result<Json<SessionTokens>, ApiError> {
    require_protocol(&headers)?;
    if request.refresh_token.is_empty() || request.refresh_token.len() > 512 {
        return Err(invalid_request("Refresh token is malformed."));
    }
    let token_hash = digest(request.refresh_token.as_bytes()).to_vec();
    let mut tx = state.db.begin().await.map_err(database_error)?;
    let record = sqlx::query_as::<_, RefreshTokenRow>(
        "SELECT r.session_id, s.account_id, s.device_id, r.refresh_family_id, r.expires_at, r.consumed_at, s.revoked_at, s.refresh_expires_at, a.deleted_at AS account_deleted_at, a.deletion_purge_at AS account_deletion_purge_at \
         FROM session_refresh_tokens r JOIN sessions s ON s.id = r.session_id JOIN accounts a ON a.id = s.account_id \
         WHERE r.token_hash = $1 FOR UPDATE OF r, s",
    )
    .bind(&token_hash)
    .fetch_optional(&mut *tx)
    .await
    .map_err(database_error)?;
    let Some(record) = record else {
        return Err(unauthorized("Refresh token is invalid or expired."));
    };
    if record.expires_at <= Utc::now()
        || record.refresh_expires_at <= Utc::now()
        || record.revoked_at.is_some()
    {
        tx.rollback().await.map_err(database_error)?;
        return Err(unauthorized("Refresh token is invalid or expired."));
    }
    if let Some(deleted_at) = record.account_deleted_at {
        tx.rollback().await.map_err(database_error)?;
        let purge_at = record
            .account_deletion_purge_at
            .unwrap_or_else(|| deleted_at + ChronoDuration::days(ACCOUNT_DELETION_GRACE_DAYS));
        return Err(account_deletion_pending_at(purge_at));
    }
    if record.consumed_at.is_some() {
        sqlx::query("UPDATE sessions SET revoked_at = COALESCE(revoked_at, now()) WHERE refresh_family_id = $1")
            .bind(record.refresh_family_id)
            .execute(&mut *tx)
            .await
            .map_err(database_error)?;
        tx.commit().await.map_err(database_error)?;
        return Err(unauthorized(
            "Refresh token reuse revoked this session. Sign in again.",
        ));
    }
    let access_token = opaque_token();
    let refresh_token = opaque_token();
    let access_expires_at = Utc::now() + ChronoDuration::minutes(ACCESS_TOKEN_MINUTES);
    let refresh_expires_at = Utc::now() + ChronoDuration::days(REFRESH_TOKEN_DAYS);
    sqlx::query("UPDATE session_refresh_tokens SET consumed_at = now() WHERE token_hash = $1")
        .bind(&token_hash)
        .execute(&mut *tx)
        .await
        .map_err(database_error)?;
    sqlx::query(
        "UPDATE sessions SET access_token_hash = $2, refresh_token_hash = $3, access_expires_at = $4, refresh_expires_at = $5 \
         WHERE id = $1",
    )
    .bind(record.session_id)
    .bind(digest(access_token.as_bytes()).to_vec())
    .bind(digest(refresh_token.as_bytes()).to_vec())
    .bind(access_expires_at)
    .bind(refresh_expires_at)
    .execute(&mut *tx)
    .await
    .map_err(database_error)?;
    sqlx::query(
        "INSERT INTO session_refresh_tokens (token_hash, session_id, refresh_family_id, expires_at) VALUES ($1, $2, $3, $4)",
    )
    .bind(digest(refresh_token.as_bytes()).to_vec())
    .bind(record.session_id)
    .bind(record.refresh_family_id)
    .bind(refresh_expires_at)
    .execute(&mut *tx)
    .await
    .map_err(database_error)?;
    sqlx::query("UPDATE devices SET last_seen_at = now() WHERE account_id = $1 AND device_id = $2")
        .bind(record.account_id)
        .bind(record.device_id)
        .execute(&mut *tx)
        .await
        .map_err(database_error)?;
    tx.commit().await.map_err(database_error)?;
    Ok(Json(SessionTokens {
        account_id: record.account_id,
        session_id: record.session_id,
        access_token,
        access_expires_at,
        refresh_token,
    }))
}

#[derive(Deserialize, Default)]
#[serde(deny_unknown_fields)]
struct RefreshRequest {
    refresh_token: String,
}

async fn revoke_session(
    State(state): State<AppState>,
    headers: HeaderMap,
    Extension(account): Extension<AuthenticatedAccount>,
    Extension(session): Extension<AuthenticatedSession>,
    Extension(context): Extension<RequestContext>,
    body: Result<Option<Json<RevokeRequest>>, JsonRejection>,
) -> axum::response::Response {
    let result = match body {
        Ok(body) => revoke_session_inner(state, headers, account, session, body).await,
        Err(_) => Err(invalid_request(
            "Request body must be a valid session-revocation request.",
        )),
    };
    auth_response(result, context)
}

async fn revoke_session_inner(
    state: AppState,
    headers: HeaderMap,
    account: AuthenticatedAccount,
    session: AuthenticatedSession,
    body: Option<Json<RevokeRequest>>,
) -> Result<StatusCode, ApiError> {
    require_protocol(&headers)?;
    if body.as_ref().is_some_and(|body| body.0.revoke_all_sessions) {
        sqlx::query(
            "UPDATE sessions SET revoked_at = COALESCE(revoked_at, now()) WHERE account_id = $1",
        )
        .bind(account.0)
        .execute(&state.db)
        .await
        .map_err(database_error)?;
    } else if let Some(session_id) = session.session_id {
        sqlx::query("UPDATE sessions SET revoked_at = COALESCE(revoked_at, now()) WHERE id = $1 AND account_id = $2")
            .bind(session_id)
            .bind(account.0)
            .execute(&state.db)
            .await
            .map_err(database_error)?;
    }
    Ok(StatusCode::NO_CONTENT)
}

async fn delete_account(
    State(state): State<AppState>,
    headers: HeaderMap,
    Extension(account): Extension<AuthenticatedAccount>,
    Extension(session): Extension<AuthenticatedSession>,
    Extension(context): Extension<RequestContext>,
) -> axum::response::Response {
    let result = delete_account_inner(state, headers, account, session).await;
    match result {
        Ok(schedule) => {
            let mut response = (StatusCode::ACCEPTED, Json(schedule)).into_response();
            response.headers_mut().insert(
                axum::http::header::CACHE_CONTROL,
                HeaderValue::from_static("no-store"),
            );
            response
        }
        Err(error) => error.into_response(context),
    }
}

async fn delete_account_inner(
    state: AppState,
    headers: HeaderMap,
    account: AuthenticatedAccount,
    session: AuthenticatedSession,
) -> Result<DeletionSchedule, ApiError> {
    require_protocol(&headers)?;
    let session_id = session
        .session_id
        .ok_or_else(|| unauthorized("A provider sign-in session is required."))?;
    let recent_auth = headers
        .get("X-Reauthentication-Token")
        .and_then(|value| value.to_str().ok())
        .filter(|value| !value.is_empty())
        .ok_or_else(|| {
            ApiError::new(
                StatusCode::FORBIDDEN,
                "reauthentication_required",
                "Reauthenticate before deleting this account.",
            )
        })?;

    let mut tx = state.db.begin().await.map_err(database_error)?;
    require_account_not_pending_deletion(&mut tx, account.0).await?;

    let auto_renewing_desktop_subscriptions = sqlx::query_scalar::<_, Uuid>(
        "SELECT id FROM subscriptions WHERE account_id = $1 \
         AND billing_provider IN ('paddle', 'stripe') AND auto_renews = true FOR UPDATE",
    )
    .bind(account.0)
    .fetch_all(&mut *tx)
    .await
    .map_err(database_error)?;
    if !auto_renewing_desktop_subscriptions.is_empty() {
        return Err(ApiError::new(
            StatusCode::CONFLICT,
            "billing_cancellation_required",
            "Cancel the desktop subscription before deleting this account.",
        ));
    }

    let subscriptions = sqlx::query_as::<_, SubscriptionResponse>(
        "SELECT id AS subscription_id, billing_provider, state, access_until, auto_renews, management_url \
         FROM subscriptions WHERE account_id = $1 ORDER BY created_at, id FOR UPDATE",
    )
    .bind(account.0)
    .fetch_all(&mut *tx)
    .await
    .map_err(database_error)?;
    let mut store_subscription_management_urls = Vec::new();
    for subscription in subscriptions {
        let access_may_continue = matches!(
            subscription.state.as_str(),
            "pending" | "active" | "grace" | "payment_retry" | "paused"
        ) && subscription
            .access_until
            .is_none_or(|access_until| access_until > Utc::now());
        if !subscription.auto_renews && !access_may_continue {
            continue;
        }
        let url = match subscription.billing_provider.as_str() {
            "apple" => Some("https://apps.apple.com/account/subscriptions"),
            "google" => Some("https://play.google.com/store/account/subscriptions"),
            _ => None,
        };
        if let Some(url) = url {
            if !store_subscription_management_urls
                .iter()
                .any(|item| item == url)
            {
                store_subscription_management_urls.push(url.to_string());
            }
        }
    }

    consume_reauthentication_proof(
        &mut tx,
        recent_auth,
        account.0,
        session_id,
        "delete_account",
    )
    .await?;
    let (access_revoked_at, data_purge_after) =
        sqlx::query_as::<_, (DateTime<Utc>, DateTime<Utc>)>(
            "WITH request_time AS (SELECT clock_timestamp() AS started_at) \
         UPDATE accounts SET deleted_at = request_time.started_at, \
         deletion_purge_at = request_time.started_at + ($2::double precision * interval '1 day') \
         FROM request_time WHERE accounts.id = $1 AND accounts.deleted_at IS NULL \
         RETURNING accounts.deleted_at, accounts.deletion_purge_at",
        )
        .bind(account.0)
        .bind(ACCOUNT_DELETION_GRACE_DAYS as f64)
        .fetch_optional(&mut *tx)
        .await
        .map_err(database_error)?
        .ok_or_else(account_deletion_pending)?;
    sqlx::query("UPDATE sessions SET revoked_at = COALESCE(revoked_at, $2) WHERE account_id = $1")
        .bind(account.0)
        .bind(access_revoked_at)
        .execute(&mut *tx)
        .await
        .map_err(database_error)?;
    sqlx::query(
        "UPDATE auth_challenges SET consumed_at = COALESCE(consumed_at, $2) \
         WHERE account_id = $1 AND consumed_at IS NULL",
    )
    .bind(account.0)
    .bind(access_revoked_at)
    .execute(&mut *tx)
    .await
    .map_err(database_error)?;
    sqlx::query(
        "UPDATE reauthentication_proofs SET consumed_at = COALESCE(consumed_at, $2) \
         WHERE account_id = $1 AND consumed_at IS NULL",
    )
    .bind(account.0)
    .bind(access_revoked_at)
    .execute(&mut *tx)
    .await
    .map_err(database_error)?;
    tx.commit().await.map_err(database_error)?;

    Ok(DeletionSchedule {
        access_revoked_at,
        data_purge_after,
        backup_purge_by: data_purge_after + ChronoDuration::days(35),
        store_subscription_management_urls,
    })
}

async fn current_account(
    State(state): State<AppState>,
    headers: HeaderMap,
    Extension(account): Extension<AuthenticatedAccount>,
    Extension(context): Extension<RequestContext>,
) -> axum::response::Response {
    auth_response(
        current_account_inner(state, headers, account).await,
        context,
    )
}

async fn current_account_inner(
    state: AppState,
    headers: HeaderMap,
    account: AuthenticatedAccount,
) -> Result<Json<AccountResponse>, ApiError> {
    require_protocol(&headers)?;
    let mut tx = state.db.begin().await.map_err(database_error)?;
    let result = account_response(&mut tx, account.0).await?;
    tx.commit().await.map_err(database_error)?;
    Ok(Json(result))
}

async fn current_entitlement(
    State(state): State<AppState>,
    headers: HeaderMap,
    Extension(account): Extension<AuthenticatedAccount>,
    Extension(context): Extension<RequestContext>,
) -> axum::response::Response {
    auth_response(
        current_entitlement_inner(state, headers, account).await,
        context,
    )
}

async fn current_entitlement_inner(
    state: AppState,
    headers: HeaderMap,
    account: AuthenticatedAccount,
) -> Result<Json<EntitlementResponse>, ApiError> {
    require_protocol(&headers)?;
    let entitlement = sqlx::query_as::<_, EntitlementRow>(
        "SELECT state, can_write, effective_expires_at, read_access_until FROM entitlements WHERE account_id = $1",
    )
    .bind(account.0)
    .fetch_optional(&state.db)
    .await
    .map_err(database_error)?;
    let subscriptions = sqlx::query_as::<_, SubscriptionResponse>(
        "SELECT id AS subscription_id, billing_provider, state, access_until, auto_renews, management_url \
         FROM subscriptions WHERE account_id = $1 ORDER BY created_at, id",
    )
    .bind(account.0)
    .fetch_all(&state.db)
    .await
    .map_err(database_error)?;
    let used_bytes = sqlx::query_scalar::<_, i64>(
        "SELECT COALESCE((SELECT SUM(current_bytes)::BIGINT FROM budgets WHERE account_id = $1), 0::BIGINT) \
         + COALESCE((SELECT SUM(byte_size)::BIGINT FROM budget_versions WHERE account_id = $1), 0::BIGINT)",
    )
    .bind(account.0)
    .fetch_one(&state.db)
    .await
    .map_err(database_error)?;

    let now = Utc::now();
    let row = entitlement.unwrap_or(EntitlementRow {
        state: "none".to_string(),
        can_write: false,
        effective_expires_at: None,
        read_access_until: None,
    });
    let has_current_access = matches!(row.state.as_str(), "active" | "grace")
        && row.can_write
        && row.effective_expires_at.is_none_or(|expiry| expiry > now);
    let can_read = has_current_access || row.read_access_until.is_some_and(|expiry| expiry > now);
    let can_write = has_current_access;
    Ok(Json(EntitlementResponse {
        plan_id: if subscriptions.is_empty() && !can_write {
            None
        } else {
            Some("cloud_monthly")
        },
        state: row.state,
        can_create: can_write,
        can_write,
        can_read,
        storage: StorageUsage {
            used_bytes,
            limit_bytes: state.config.account_storage_limit_bytes,
        },
        subscriptions,
        effective_expires_at: row.effective_expires_at,
        read_access_until: row.read_access_until,
    }))
}

async fn verify_challenge(
    state: &AppState,
    provider: ProviderName,
    challenge_id: Uuid,
    supplied_state: &str,
    authorization_code: Option<&str>,
    pkce_verifier: Option<&str>,
    identity_token: Option<&str>,
    linking: bool,
) -> ApiResult<(ChallengeRow, ProviderIdentity)> {
    if supplied_state.len() != 128 {
        return Err(invalid_provider_proof());
    }
    let challenge = sqlx::query_as::<_, ChallengeRow>(
        "SELECT id, provider, purpose, platform, flow, redirect_uri, client_id, state_hash, nonce, device_id, pkce_challenge, account_id, session_id, expires_at, consumed_at \
         FROM auth_challenges WHERE id = $1",
    )
    .bind(challenge_id)
    .fetch_optional(&state.db)
    .await
    .map_err(database_error)?
    .ok_or_else(challenge_expired)?;
    if challenge.provider != provider.as_str() {
        return Err(invalid_provider_proof());
    }
    if challenge.expires_at <= Utc::now() || challenge.consumed_at.is_some() {
        return Err(challenge_expired());
    }
    let supplied_hash = digest(supplied_state.as_bytes());
    if challenge.state_hash.len() != supplied_hash.len()
        || !bool::from(challenge.state_hash.as_slice().ct_eq(&supplied_hash))
    {
        return Err(invalid_provider_proof());
    }

    if (challenge.purpose == "link_identity") != linking {
        return Err(invalid_request(
            "Challenge purpose does not match this endpoint.",
        ));
    }

    let id_token = match challenge.flow.as_str() {
        "native" => {
            if identity_token.is_none() || authorization_code.is_some() || pkce_verifier.is_some() {
                return Err(invalid_request(
                    "Native flow requires exactly one identity token.",
                ));
            }
            let identity_token =
                identity_token.ok_or_else(|| invalid_request("Identity token is required."))?;
            if identity_token.len() > 32 * 1024 {
                return Err(invalid_request("Identity token is too large."));
            }
            identity_token.to_string()
        }
        "browser" => {
            if identity_token.is_some() || authorization_code.is_none() {
                return Err(invalid_request(
                    "Browser flow requires exactly one authorization code.",
                ));
            }
            let code = authorization_code
                .ok_or_else(|| invalid_request("Authorization code is required."))?;
            if code.is_empty() || code.len() > 8192 {
                return Err(invalid_request("Authorization code is malformed."));
            }
            let verifier = match (&challenge.pkce_challenge, pkce_verifier) {
                (Some(expected), Some(actual)) => {
                    if !valid_pkce_verifier(actual) {
                        return Err(invalid_provider_proof());
                    }
                    let actual_hash = URL_SAFE_NO_PAD.encode(Sha256::digest(actual.as_bytes()));
                    if actual_hash != *expected {
                        return Err(invalid_provider_proof());
                    }
                    Some(actual)
                }
                (Some(_), None) => {
                    return Err(invalid_request("This challenge requires a PKCE verifier."));
                }
                (None, Some(_)) => {
                    return Err(invalid_request("This challenge does not use PKCE."));
                }
                (None, None) => None,
            };
            state
                .provider_verifier
                .exchange_code(
                    provider,
                    provider_config(&state.config, provider),
                    &challenge.client_id,
                    challenge
                        .redirect_uri
                        .as_deref()
                        .ok_or_else(challenge_expired)?,
                    code,
                    verifier,
                )
                .await
                .map_err(provider_error)?
        }
        _ => return Err(challenge_expired()),
    };
    let identity = state
        .provider_verifier
        .verify_identity_token(provider, &id_token, &challenge.client_id, &challenge.nonce)
        .await
        .map_err(provider_error)?;
    Ok((challenge, identity))
}

async fn lock_live_challenge(
    tx: &mut Transaction<'_, Postgres>,
    challenge: &ChallengeRow,
    supplied_state: &str,
) -> ApiResult<ChallengeRow> {
    // Serialize account-bound auth on the account before locking challenges or
    // proofs, matching account deletion and retention maintenance.
    if let Some(account_id) = challenge.account_id {
        require_account_not_pending_deletion(tx, account_id).await?;
    }
    let locked = sqlx::query_as::<_, ChallengeRow>(
        "SELECT id, provider, purpose, platform, flow, redirect_uri, client_id, state_hash, nonce, device_id, pkce_challenge, account_id, session_id, expires_at, consumed_at \
         FROM auth_challenges WHERE id = $1 FOR UPDATE",
    )
    .bind(challenge.id)
    .fetch_optional(&mut **tx)
    .await
    .map_err(database_error)?
    .ok_or_else(challenge_expired)?;
    let supplied_hash = digest(supplied_state.as_bytes());
    if locked.expires_at <= Utc::now()
        || locked.consumed_at.is_some()
        || locked.state_hash.len() != supplied_hash.len()
        || !bool::from(locked.state_hash.as_slice().ct_eq(&supplied_hash))
    {
        return Err(challenge_expired());
    }
    Ok(locked)
}

async fn sign_in(
    tx: &mut Transaction<'_, Postgres>,
    challenge: &ChallengeRow,
    provider: ProviderName,
    identity: ProviderIdentity,
) -> ApiResult<(AccountResponse, SessionTokens)> {
    let issuer = canonical_issuer(provider);
    let existing = sqlx::query_as::<_, AccountCreated>(
        "SELECT a.id, a.created_at, a.deleted_at, a.deletion_purge_at FROM auth_identities i JOIN accounts a ON a.id = i.account_id \
         WHERE i.provider = $1 AND i.issuer = $2 AND i.subject = $3 FOR UPDATE OF a",
    )
    .bind(provider.as_str())
    .bind(issuer)
    .bind(&identity.subject)
    .fetch_optional(&mut **tx)
    .await
    .map_err(database_error)?;
    let account = if let Some(existing) = existing {
        if let Some(deleted_at) = existing.deleted_at {
            let purge_at = existing
                .deletion_purge_at
                .unwrap_or_else(|| deleted_at + ChronoDuration::days(ACCOUNT_DELETION_GRACE_DAYS));
            return Err(account_deletion_pending_at(purge_at));
        }
        sqlx::query("UPDATE auth_identities SET display_email = COALESCE($2, display_email) WHERE provider = $1 AND issuer = $3 AND subject = $4")
            .bind(provider.as_str())
            .bind(&identity.display_email)
            .bind(issuer)
            .bind(&identity.subject)
            .execute(&mut **tx)
            .await
            .map_err(database_error)?;
        existing
    } else {
        let new_account_id = Uuid::new_v4();
        sqlx::query("INSERT INTO accounts (id) VALUES ($1)")
            .bind(new_account_id)
            .execute(&mut **tx)
            .await
            .map_err(database_error)?;
        sqlx::query(
            "INSERT INTO auth_identities (id, account_id, provider, issuer, subject, display_email) \
             VALUES ($1, $2, $3, $4, $5, $6) ON CONFLICT (provider, issuer, subject) DO NOTHING",
        )
        .bind(Uuid::new_v4())
        .bind(new_account_id)
        .bind(provider.as_str())
        .bind(issuer)
        .bind(&identity.subject)
        .bind(&identity.display_email)
        .execute(&mut **tx)
        .await
        .map_err(database_error)?;
        let owner = sqlx::query_as::<_, AccountCreated>(
            "SELECT a.id, a.created_at, a.deleted_at, a.deletion_purge_at FROM auth_identities i JOIN accounts a ON a.id = i.account_id \
             WHERE i.provider = $1 AND i.issuer = $2 AND i.subject = $3 FOR UPDATE OF a",
        )
        .bind(provider.as_str())
        .bind(issuer)
        .bind(&identity.subject)
        .fetch_one(&mut **tx)
        .await
        .map_err(database_error)?;
        if owner.id != new_account_id {
            sqlx::query("DELETE FROM accounts WHERE id = $1")
                .bind(new_account_id)
                .execute(&mut **tx)
                .await
                .map_err(database_error)?;
        }
        if let Some(deleted_at) = owner.deleted_at {
            let purge_at = owner
                .deletion_purge_at
                .unwrap_or_else(|| deleted_at + ChronoDuration::days(ACCOUNT_DELETION_GRACE_DAYS));
            return Err(account_deletion_pending_at(purge_at));
        }
        owner
    };

    let device_id = challenge.device_id;
    sqlx::query(
        "INSERT INTO devices (account_id, device_id, platform) VALUES ($1, $2, $3) \
         ON CONFLICT (account_id, device_id) DO UPDATE SET platform = EXCLUDED.platform, last_seen_at = now()",
    )
    .bind(account.id)
    .bind(device_id)
    .bind(&challenge.platform)
    .execute(&mut **tx)
    .await
    .map_err(database_error)?;
    sqlx::query("UPDATE sessions SET revoked_at = COALESCE(revoked_at, now()) WHERE account_id = $1 AND device_id = $2 AND revoked_at IS NULL")
        .bind(account.id)
        .bind(device_id)
        .execute(&mut **tx)
        .await
        .map_err(database_error)?;

    let session_id = Uuid::new_v4();
    let refresh_family_id = Uuid::new_v4();
    let access_token = opaque_token();
    let refresh_token = opaque_token();
    let access_expires_at = Utc::now() + ChronoDuration::minutes(ACCESS_TOKEN_MINUTES);
    let refresh_expires_at = Utc::now() + ChronoDuration::days(REFRESH_TOKEN_DAYS);
    let access_hash = digest(access_token.as_bytes()).to_vec();
    let refresh_hash = digest(refresh_token.as_bytes()).to_vec();
    sqlx::query(
        "INSERT INTO sessions (id, account_id, device_id, access_token_hash, refresh_token_hash, refresh_family_id, access_expires_at, refresh_expires_at) \
         VALUES ($1, $2, $3, $4, $5, $6, $7, $8)",
    )
    .bind(session_id)
    .bind(account.id)
    .bind(device_id)
    .bind(access_hash)
    .bind(&refresh_hash)
    .bind(refresh_family_id)
    .bind(access_expires_at)
    .bind(refresh_expires_at)
    .execute(&mut **tx)
    .await
    .map_err(database_error)?;
    sqlx::query("INSERT INTO session_refresh_tokens (token_hash, session_id, refresh_family_id, expires_at) VALUES ($1, $2, $3, $4)")
        .bind(refresh_hash)
        .bind(session_id)
        .bind(refresh_family_id)
        .bind(refresh_expires_at)
        .execute(&mut **tx)
        .await
        .map_err(database_error)?;

    let account_response = account_response(tx, account.id).await?;
    Ok((
        account_response,
        SessionTokens {
            account_id: account.id,
            session_id,
            access_token,
            access_expires_at,
            refresh_token,
        },
    ))
}

async fn account_response(
    tx: &mut Transaction<'_, Postgres>,
    account_id: Uuid,
) -> ApiResult<AccountResponse> {
    let account = sqlx::query_as::<_, AccountCreated>(
        "SELECT id, created_at, deleted_at, deletion_purge_at FROM accounts WHERE id = $1 AND deleted_at IS NULL",
    )
    .bind(account_id)
    .fetch_optional(&mut **tx)
    .await
    .map_err(database_error)?
    .ok_or_else(account_deletion_pending)?;
    let identities = sqlx::query_as::<_, AccountIdentity>(
        "SELECT provider, display_email, linked_at FROM auth_identities WHERE account_id = $1 ORDER BY linked_at, provider",
    )
    .bind(account_id)
    .fetch_all(&mut **tx)
    .await
    .map_err(database_error)?;
    Ok(AccountResponse {
        account_id: account.id,
        identities,
        created_at: account.created_at,
    })
}

async fn require_linked_identity(
    tx: &mut Transaction<'_, Postgres>,
    account_id: Uuid,
    provider: ProviderName,
    identity: &ProviderIdentity,
) -> ApiResult<()> {
    let linked = sqlx::query_scalar::<_, bool>(
        "SELECT EXISTS(SELECT 1 FROM auth_identities WHERE account_id = $1 AND provider = $2 AND issuer = $3 AND subject = $4)",
    )
    .bind(account_id)
    .bind(provider.as_str())
    .bind(canonical_issuer(provider))
    .bind(&identity.subject)
    .fetch_one(&mut **tx)
    .await
    .map_err(database_error)?;
    if !linked {
        return Err(invalid_provider_proof());
    }
    Ok(())
}

async fn consume_reauthentication_proof(
    tx: &mut Transaction<'_, Postgres>,
    token: &str,
    account_id: Uuid,
    session_id: Uuid,
    purpose: &str,
) -> ApiResult<()> {
    let result = sqlx::query(
        "UPDATE reauthentication_proofs SET consumed_at = now() WHERE token_hash = $1 AND account_id = $2 AND session_id = $3 AND purpose = $4 AND consumed_at IS NULL AND expires_at > now()",
    )
    .bind(digest(token.as_bytes()).to_vec())
    .bind(account_id)
    .bind(session_id)
    .bind(purpose)
    .execute(&mut **tx)
    .await
    .map_err(database_error)?;
    if result.rows_affected() != 1 {
        return Err(ApiError::new(
            StatusCode::FORBIDDEN,
            "reauthentication_required",
            "Reauthenticate before continuing.",
        ));
    }
    Ok(())
}

async fn require_account_not_pending_deletion(
    tx: &mut Transaction<'_, Postgres>,
    account_id: Uuid,
) -> ApiResult<()> {
    let (deleted_at, deletion_purge_at) =
        sqlx::query_as::<_, (Option<DateTime<Utc>>, Option<DateTime<Utc>>)>(
            "SELECT deleted_at, deletion_purge_at FROM accounts WHERE id = $1 FOR UPDATE",
        )
        .bind(account_id)
        .fetch_optional(&mut **tx)
        .await
        .map_err(database_error)?
        .ok_or_else(|| unauthorized("Account is unavailable."))?;
    if let Some(deleted_at) = deleted_at {
        let purge_at = deletion_purge_at
            .unwrap_or_else(|| deleted_at + ChronoDuration::days(ACCOUNT_DELETION_GRACE_DAYS));
        return Err(account_deletion_pending_at(purge_at));
    }
    Ok(())
}

async fn authenticated_session(
    state: &AppState,
    headers: &HeaderMap,
) -> ApiResult<AuthenticatedSession> {
    let token = headers
        .get("Authorization")
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.strip_prefix("Bearer "))
        .filter(|value| !value.trim().is_empty())
        .ok_or_else(|| unauthorized("Sign in to continue."))?;
    let token_hash = digest(token.as_bytes());
    if state.config.environment == "development"
        && state
            .config
            .dev_bearer_token_hash
            .is_some_and(|expected| bool::from(expected.ct_eq(&token_hash)))
    {
        let account_id = state
            .config
            .dev_account_id
            .ok_or_else(|| unauthorized("Sign in to continue."))?;
        let exists = sqlx::query_scalar::<_, bool>(
            "SELECT EXISTS(SELECT 1 FROM accounts WHERE id = $1 AND deleted_at IS NULL)",
        )
        .bind(account_id)
        .fetch_one(&state.db)
        .await
        .map_err(database_error)?;
        return if exists {
            Ok(AuthenticatedSession {
                account_id,
                session_id: None,
            })
        } else {
            Err(unauthorized("Sign in to continue."))
        };
    }
    let result = sqlx::query_as::<_, (Uuid, Uuid)>(
        "SELECT s.account_id, s.id FROM sessions s JOIN accounts a ON a.id = s.account_id \
         WHERE s.access_token_hash = $1 AND s.access_expires_at > now() AND s.revoked_at IS NULL AND a.deleted_at IS NULL",
    )
    .bind(token_hash.to_vec())
    .fetch_optional(&state.db)
    .await
    .map_err(database_error)?;
    result
        .map(|(account_id, session_id)| AuthenticatedSession {
            account_id,
            session_id: Some(session_id),
        })
        .ok_or_else(|| unauthorized("Sign in to continue."))
}

fn provider_config(config: &Config, provider: ProviderName) -> &ProviderConfig {
    match provider {
        ProviderName::Google => &config.google_auth,
        ProviderName::Apple => &config.apple_auth,
    }
}

fn authorization_url(
    provider: ProviderName,
    client_id: &str,
    redirect_uri: &str,
    state: &str,
    nonce: &str,
    pkce_challenge: Option<&str>,
    reauthenticate: bool,
) -> ApiResult<String> {
    let endpoint = match provider {
        ProviderName::Google => "https://accounts.google.com/o/oauth2/v2/auth",
        ProviderName::Apple => "https://appleid.apple.com/auth/authorize",
    };
    let mut url = Url::parse(endpoint).map_err(|_| provider_unavailable())?;
    {
        let mut query = url.query_pairs_mut();
        query
            .append_pair("client_id", client_id)
            .append_pair("redirect_uri", redirect_uri)
            .append_pair("response_type", "code")
            .append_pair("state", state)
            .append_pair("nonce", nonce);
        match provider {
            ProviderName::Google => {
                query.append_pair("scope", "openid email profile");
            }
            ProviderName::Apple => {
                query.append_pair("scope", "email name");
                query.append_pair("response_mode", "form_post");
            }
        }
        if reauthenticate {
            if provider == ProviderName::Google {
                query.append_pair("prompt", "select_account");
            }
            query.append_pair("max_age", "0");
        }
        if let Some(challenge) = pkce_challenge {
            query
                .append_pair("code_challenge", challenge)
                .append_pair("code_challenge_method", "S256");
        }
    }
    Ok(url.to_string())
}

fn canonical_issuer(provider: ProviderName) -> &'static str {
    match provider {
        ProviderName::Google => "https://accounts.google.com",
        ProviderName::Apple => "https://appleid.apple.com",
    }
}

fn opaque_token() -> String {
    format!(
        "{}{}{}{}",
        Uuid::new_v4().simple(),
        Uuid::new_v4().simple(),
        Uuid::new_v4().simple(),
        Uuid::new_v4().simple()
    )
}

fn valid_pkce_challenge(value: &str) -> bool {
    value.len() == 43
        && URL_SAFE_NO_PAD
            .decode(value)
            .is_ok_and(|decoded| decoded.len() == 32)
}

fn valid_pkce_verifier(value: &str) -> bool {
    (43..=128).contains(&value.len())
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || b"-._~".contains(&byte))
}

fn require_protocol(headers: &HeaderMap) -> ApiResult<()> {
    let Some(protocol) = headers.get("Budget-Warden-Protocol") else {
        return Err(invalid_request("Budget-Warden-Protocol is required."));
    };
    if protocol.as_bytes() != b"1" {
        return Err(ApiError::new(
            StatusCode::UPGRADE_REQUIRED,
            "protocol_unsupported",
            "This protocol version is not supported.",
        )
        .with_details(serde_json::json!({ "supported_protocol_versions": [1] })));
    }
    Ok(())
}

fn provider_error(error: ProviderError) -> ApiError {
    match error {
        ProviderError::InvalidProof => invalid_provider_proof(),
        ProviderError::Unavailable => provider_unavailable(),
    }
}

fn provider_unavailable() -> ApiError {
    ApiError::new(
        StatusCode::SERVICE_UNAVAILABLE,
        "service_unavailable",
        "The identity provider is not configured or is temporarily unavailable.",
    )
}

fn invalid_provider_proof() -> ApiError {
    ApiError::new(
        StatusCode::UNAUTHORIZED,
        "invalid_provider_proof",
        "The provider could not verify this sign-in proof.",
    )
}

fn challenge_expired() -> ApiError {
    ApiError::new(
        StatusCode::BAD_REQUEST,
        "challenge_expired",
        "The sign-in challenge is expired or has already been used.",
    )
}

fn unauthorized(detail: &'static str) -> ApiError {
    ApiError::new(StatusCode::UNAUTHORIZED, "session_expired", detail)
}

fn account_deletion_pending() -> ApiError {
    ApiError::new(
        StatusCode::FORBIDDEN,
        "account_deletion_pending",
        "This account is scheduled for deletion.",
    )
}

fn account_deletion_pending_at(purge_at: DateTime<Utc>) -> ApiError {
    ApiError::new(
        StatusCode::FORBIDDEN,
        "account_deletion_pending",
        format!("This account is scheduled for deletion on {purge_at} UTC."),
    )
    .with_details(serde_json::json!({ "data_purge_after": purge_at }))
}

fn identity_already_linked() -> ApiError {
    ApiError::new(
        StatusCode::CONFLICT,
        "identity_already_linked",
        "This provider identity is already linked to an account.",
    )
}

fn auth_response<T: IntoResponse>(
    result: Result<T, ApiError>,
    context: RequestContext,
) -> axum::response::Response {
    match result {
        Ok(response) => response.into_response(),
        Err(error) => error.into_response(context),
    }
}
