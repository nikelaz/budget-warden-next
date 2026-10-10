//! Persistent fixed-window rate limits for sign-in and session routes.
//!
//! Counters live in PostgreSQL so limits hold across restarts and across
//! server instances. The client address comes from the socket, or from the
//! first `X-Forwarded-For` entry only when `BW_TRUST_PROXY_HEADERS` is set.

use std::net::SocketAddr;

use axum::{
    body::Body,
    extract::{ConnectInfo, Request, State},
    http::{StatusCode, header::HeaderValue},
    middleware::Next,
    response::Response,
};
use sqlx::PgPool;

use crate::{
    errors::{ApiError, ApiResult, RequestContext, database_error},
    state::AppState,
};

const WINDOW_SECONDS: f64 = 60.0;

pub async fn check(pool: &PgPool, bucket: &str, limit: i32) -> ApiResult<()> {
    let hits = sqlx::query_scalar::<_, i32>(
        "INSERT INTO auth_rate_limits (bucket, window_started_at, hits) VALUES ($1, clock_timestamp(), 1) \
         ON CONFLICT (bucket) DO UPDATE SET \
           window_started_at = CASE WHEN auth_rate_limits.window_started_at <= clock_timestamp() - make_interval(secs => $2) \
             THEN clock_timestamp() ELSE auth_rate_limits.window_started_at END, \
           hits = CASE WHEN auth_rate_limits.window_started_at <= clock_timestamp() - make_interval(secs => $2) \
             THEN 1 ELSE auth_rate_limits.hits + 1 END \
         RETURNING hits",
    )
    .bind(bucket)
    .bind(WINDOW_SECONDS)
    .fetch_one(pool)
    .await
    .map_err(database_error)?;
    if hits > limit {
        return Err(ApiError::new(
            StatusCode::TOO_MANY_REQUESTS,
            "rate_limited",
            "Too many requests. Try again shortly.",
        )
        .with_details(serde_json::json!({ "retry_after_seconds": WINDOW_SECONDS as i64 })));
    }
    Ok(())
}

fn client_address(request: &Request<Body>, trust_proxy: bool) -> String {
    if trust_proxy
        && let Some(forwarded) = request
            .headers()
            .get("x-forwarded-for")
            .and_then(|value| value.to_str().ok())
            .and_then(|value| value.split(',').next())
            .map(str::trim)
            .filter(|value| !value.is_empty())
    {
        return forwarded.to_owned();
    }
    request
        .extensions()
        .get::<ConnectInfo<SocketAddr>>()
        .map(|ConnectInfo(address)| address.ip().to_string())
        .unwrap_or_else(|| "unknown".to_owned())
}

/// Route layer that limits each client address per route.
pub async fn limit_sign_in(
    State(state): State<AppState>,
    request: Request<Body>,
    next: Next,
) -> Response {
    let context = request
        .extensions()
        .get::<RequestContext>()
        .copied()
        .unwrap_or(RequestContext {
            id: uuid::Uuid::new_v4(),
        });
    let bucket = format!(
        "{}:{}",
        request.uri().path(),
        client_address(&request, state.config.trust_proxy_headers)
    );
    if let Err(error) = check(&state.db, &bucket, state.config.auth_rate_limit_per_minute).await {
        let mut response = error.into_response(context);
        response
            .headers_mut()
            .insert("retry-after", HeaderValue::from_static("60"));
        return response;
    }
    next.run(request).await
}
