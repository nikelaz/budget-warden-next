use axum::{
    extract::State,
    http::{Request, StatusCode, header::AUTHORIZATION},
    middleware::Next,
    response::Response,
};
use subtle::ConstantTimeEq;
use uuid::Uuid;

use crate::{
    errors::{ApiError, RequestContext},
    state::AppState,
    tokens::digest,
};

#[derive(Clone, Copy, Debug)]
pub struct AuthenticatedAccount(pub Uuid);

#[derive(Clone, Copy, Debug)]
pub struct AuthenticatedSession {
    pub account_id: Uuid,
    pub session_id: Option<Uuid>,
}

pub async fn require_auth(
    State(state): State<AppState>,
    mut request: Request<axum::body::Body>,
    next: Next,
) -> Response {
    let context = request
        .extensions()
        .get::<RequestContext>()
        .copied()
        .unwrap_or(RequestContext { id: Uuid::new_v4() });

    let protocol = request.headers().get("Budget-Warden-Protocol");
    let Some(protocol) = protocol else {
        return ApiError::new(
            StatusCode::BAD_REQUEST,
            "invalid_request",
            "Budget-Warden-Protocol is required.",
        )
        .into_response(context);
    };
    if protocol.as_bytes() != b"1" {
        return ApiError::new(
            StatusCode::UPGRADE_REQUIRED,
            "protocol_unsupported",
            "This protocol version is not supported.",
        )
        .with_details(serde_json::json!({ "supported_protocol_versions": [1] }))
        .into_response(context);
    }

    let token = request
        .headers()
        .get(AUTHORIZATION)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.strip_prefix("Bearer "))
        .filter(|value| !value.trim().is_empty());

    let Some(token) = token else {
        return session_expired(context);
    };

    let token_digest = digest(token.as_bytes());
    let dev_account = state
        .config
        .dev_bearer_token_hash
        .filter(|expected| {
            state.config.environment == "development" && bool::from(expected.ct_eq(&token_digest))
        })
        .and(state.config.dev_account_id);
    let authenticated = match if let Some(account_id) = dev_account {
        sqlx::query_scalar::<_, Uuid>(
            "SELECT id FROM accounts WHERE id = $1 AND deleted_at IS NULL",
        )
        .bind(account_id)
        .fetch_optional(&state.db)
        .await
        .map(|value| value.map(|account_id| (account_id, None)))
    } else {
        sqlx::query_as::<_, (Uuid, Uuid)>(
            "SELECT s.account_id, s.id FROM sessions s JOIN accounts a ON a.id = s.account_id \
             WHERE s.access_token_hash = $1 AND s.access_expires_at > now() \
             AND s.revoked_at IS NULL AND a.deleted_at IS NULL",
        )
        .bind(token_digest.to_vec())
        .fetch_optional(&state.db)
        .await
        .map(|value| value.map(|(account_id, session_id)| (account_id, Some(session_id))))
    } {
        Ok(authenticated) => authenticated,
        Err(error) => return ApiError::internal(error).into_response(context),
    };

    let Some((account_id, session_id)) = authenticated else {
        return session_expired(context);
    };

    request
        .extensions_mut()
        .insert(AuthenticatedAccount(account_id));
    request.extensions_mut().insert(AuthenticatedSession {
        account_id,
        session_id,
    });
    next.run(request).await
}

fn session_expired(context: RequestContext) -> Response {
    ApiError::new(
        StatusCode::UNAUTHORIZED,
        "session_expired",
        "Sign in again to continue.",
    )
    .into_response(context)
}
