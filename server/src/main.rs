mod auth;
mod auth_routes;
mod billing;
mod budgets;
mod config;
mod db;
mod envelope;
mod errors;
mod jobs;
mod middleware;
mod provider;
mod ratelimit;
mod state;
mod tokens;

use axum::{
    Json, Router,
    extract::{DefaultBodyLimit, Extension, State},
    http::StatusCode,
    middleware as axum_middleware,
    response::{IntoResponse, Response},
    routing::get,
};
use errors::{ApiError, RequestContext};
use serde_json::json;
use state::AppState;
use tokio::sync::watch;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let _ = dotenvy::dotenv();
    tracing_subscriber::fmt()
        .json()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info")),
        )
        .init();

    let config = config::Config::from_env().map_err(std::io::Error::other)?;
    let db = db::connect(&config).await?;
    let state = AppState {
        db: db.clone(),
        config: config.clone(),
        provider_verifier: provider::ProviderVerifier::new().map_err(std::io::Error::other)?,
        billing: billing::BillingClients::new().map_err(std::io::Error::other)?,
    };
    let billing_state = state.clone();
    let app = Router::new()
        .route("/healthz", get(health))
        .route("/v1/capabilities", get(budgets::capabilities))
        .merge(auth_routes::routes(state.clone()))
        .merge(budgets::routes(state.clone()))
        .merge(billing::routes::routes(state.clone()))
        .fallback(not_found)
        .layer(DefaultBodyLimit::max(config.max_request_body_bytes))
        .layer(axum_middleware::from_fn(middleware::request_context))
        .with_state(state);
    let listener = tokio::net::TcpListener::bind(config.listen_addr).await?;

    tracing::info!(
        environment = %config.environment,
        listen_addr = %config.listen_addr,
        "cloud server listening"
    );

    let (shutdown_tx, shutdown_rx) = watch::channel(false);
    let retention_task = tokio::spawn(jobs::run_retention_worker(db, config, shutdown_rx.clone()));
    let billing_task = tokio::spawn(billing::worker::run_billing_worker(
        billing_state,
        shutdown_rx,
    ));
    let serve_result = axum::serve(
        listener,
        app.into_make_service_with_connect_info::<std::net::SocketAddr>(),
    )
    .with_graceful_shutdown(shutdown_signal(shutdown_tx.clone()))
    .await;
    let _ = shutdown_tx.send(true);
    retention_task.await?;
    billing_task.await?;
    serve_result?;
    Ok(())
}

async fn health(State(state): State<AppState>) -> Response {
    match sqlx::query_scalar::<_, i32>("SELECT 1")
        .fetch_one(&state.db)
        .await
    {
        Ok(_) => (StatusCode::OK, Json(json!({ "status": "ok" }))).into_response(),
        Err(error) => {
            tracing::error!(error = %error, "health check database query failed");
            (
                StatusCode::SERVICE_UNAVAILABLE,
                Json(json!({ "status": "unavailable" })),
            )
                .into_response()
        }
    }
}

async fn not_found(Extension(context): Extension<RequestContext>) -> Response {
    ApiError::new(
        StatusCode::NOT_FOUND,
        "not_found",
        "The requested API route was not found.",
    )
    .into_response(context)
}

async fn shutdown_signal(shutdown_tx: watch::Sender<bool>) {
    #[cfg(unix)]
    {
        use tokio::signal::unix::{SignalKind, signal};
        let mut terminate = signal(SignalKind::terminate()).expect("register SIGTERM handler");
        tokio::select! {
            _ = tokio::signal::ctrl_c() => tracing::info!("received interrupt signal"),
            _ = terminate.recv() => tracing::info!("received termination signal"),
        }
    }
    #[cfg(not(unix))]
    {
        let _ = tokio::signal::ctrl_c().await;
        tracing::info!("received interrupt signal");
    }
    let _ = shutdown_tx.send(true);
}
