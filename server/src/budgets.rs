use axum::{
    Json, Router,
    body::Bytes,
    extract::{
        Extension, Path, Query, State,
        rejection::{BytesRejection, QueryRejection},
    },
    http::{
        HeaderMap, HeaderValue, StatusCode,
        header::{CONTENT_TYPE, ETAG},
    },
    middleware,
    response::{IntoResponse, Response},
    routing::get,
};
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use serde_json::{Value, value::RawValue};
use sha2::{Digest, Sha256};
use sqlx::{FromRow, Postgres, Transaction};
use uuid::Uuid;

use crate::{
    auth::{self, AuthenticatedAccount},
    envelope::{self, ValidatedEnvelope},
    errors::{ApiError, ApiResult, RequestContext, database_error, invalid_request},
    state::AppState,
    tokens,
};

const CREATE_ROUTE: &str = "/v1/budgets";

pub fn routes(state: AppState) -> Router<AppState> {
    Router::new()
        .route("/v1/budgets", get(list_budgets).post(create_budget))
        .route(
            "/v1/budgets/{budget_id}",
            get(get_budget).put(replace_budget).delete(delete_budget),
        )
        .route("/v1/sync/changes", get(changes))
        .route_layer(middleware::from_fn_with_state(
            state.clone(),
            auth::require_auth,
        ))
}

pub async fn capabilities(State(state): State<AppState>) -> Json<Value> {
    Json(serde_json::json!({
        "protocol_versions": [1],
        "budget_schema_versions": [bw_core::models::CURRENT_SCHEMA_VERSION],
        "envelope_versions": envelope::SUPPORTED_ENVELOPE_VERSIONS,
        "envelope_suites": [envelope::SUITE_ID],
        "minimum_client_version": state.config.minimum_client_version,
        "limits": {
            "snapshot_bytes": state.config.max_snapshot_bytes,
            "request_body_bytes": state.config.max_request_body_bytes,
            "account_storage_bytes": state.config.account_storage_limit_bytes,
            "budget_count_cap": Value::Null,
            "catalog_page_size": 100,
            "change_page_size": 100
        }
    }))
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct CreateRequest {
    cloud_budget_id: Uuid,
    envelope: Box<RawValue>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ReplaceRequest {
    envelope: Box<RawValue>,
}

#[derive(Serialize, Deserialize)]
struct BudgetReceipt {
    cloud_budget_id: Uuid,
    portable_budget_id: Uuid,
    server_version: String,
    updated_at: DateTime<Utc>,
}

#[derive(Serialize)]
struct CloudBudgetResponse {
    cloud_budget_id: Uuid,
    portable_budget_id: Uuid,
    server_version: String,
    updated_at: DateTime<Utc>,
    envelope: Value,
}

#[derive(Serialize)]
struct CatalogPage {
    items: Vec<BudgetSummary>,
    bootstrap_cursor: Option<String>,
    next_page_token: Option<String>,
}

#[derive(Serialize)]
struct BudgetSummary {
    cloud_budget_id: Uuid,
    portable_budget_id: Uuid,
    schema_version: i32,
    server_version: String,
    updated_at: DateTime<Utc>,
}

#[derive(FromRow)]
struct CatalogRow {
    cloud_budget_id: Uuid,
    portable_budget_id: Uuid,
    schema_version: i32,
    server_version: String,
    updated_at: DateTime<Utc>,
}

#[derive(FromRow)]
struct BudgetRow {
    portable_budget_id: Uuid,
    snapshot_json: Option<String>,
    current_bytes: i64,
    server_version: String,
    updated_at: DateTime<Utc>,
    deleted_at: Option<DateTime<Utc>>,
    deletion_reason: Option<String>,
}

#[derive(FromRow)]
struct ReceiptRow {
    request_digest: Vec<u8>,
    response_status: i16,
    response_body: Option<String>,
    server_version: Option<String>,
}

#[derive(Deserialize, Serialize)]
struct PageToken {
    version: u8,
    kind: String,
    account_id: Uuid,
    bootstrap_sequence: i64,
    last_cloud_budget_id: Uuid,
    page_size: usize,
    issued_at: i64,
}

#[derive(Deserialize)]
struct CatalogQuery {
    page_size: Option<usize>,
    page_token: Option<String>,
}

async fn list_budgets(
    State(state): State<AppState>,
    Extension(AuthenticatedAccount(account_id)): Extension<AuthenticatedAccount>,
    Extension(context): Extension<RequestContext>,
    query: Result<Query<CatalogQuery>, QueryRejection>,
) -> Response {
    let Query(query) = match query {
        Ok(query) => query,
        Err(_) => return invalid_request("The catalog query is malformed.").into_response(context),
    };
    match list_budgets_inner(&state, account_id, query).await {
        Ok(page) => Json(page).into_response(),
        Err(error) => error.into_response(context),
    }
}

async fn list_budgets_inner(
    state: &AppState,
    account_id: Uuid,
    query: CatalogQuery,
) -> ApiResult<CatalogPage> {
    let now = Utc::now().timestamp();
    let (bootstrap_sequence, last_id, page_size, issued_at) = match query.page_token {
        None => {
            let page_size = checked_page_size(query.page_size, state.config.catalog_page_size)?;
            let mut tx = state.db.begin().await.map_err(database_error)?;
            let sequence = sqlx::query_scalar::<_, i64>(
                "SELECT next_change_seq FROM accounts WHERE id = $1 AND deleted_at IS NULL FOR SHARE",
            )
            .bind(account_id)
            .fetch_optional(&mut *tx)
            .await
            .map_err(database_error)?
            .ok_or_else(not_found)?;
            let rows = catalog_rows(&mut tx, account_id, sequence, None, page_size + 1).await?;
            tx.commit().await.map_err(database_error)?;
            let (items, next_page_token) =
                make_catalog_page(state, account_id, sequence, None, page_size, now, rows)?;
            let cursor = encode_change_cursor(state, account_id, sequence)?;
            return Ok(CatalogPage {
                items,
                bootstrap_cursor: Some(cursor),
                next_page_token,
            });
        }
        Some(token) => {
            if token.len() > 2048 {
                return Err(invalid_request("The page token is too long."));
            }
            let token: PageToken =
                tokens::verify(&state.config.cursor_secret, &token).map_err(|_| {
                    ApiError::new(
                        StatusCode::BAD_REQUEST,
                        "invalid_request",
                        "The page token is invalid.",
                    )
                })?;
            if token.version != 1 || token.kind != "catalog" || token.account_id != account_id {
                return Err(invalid_request(
                    "The page token is invalid for this account.",
                ));
            }
            if now > token.issued_at + 24 * 60 * 60 || token.issued_at > now + 60 {
                return Err(ApiError::new(
                    StatusCode::GONE,
                    "page_token_expired",
                    "Restart the catalog scan from its first page.",
                ));
            }
            if query
                .page_size
                .is_some_and(|value| value != token.page_size)
            {
                return Err(invalid_request(
                    "The page size must match the first catalog page.",
                ));
            }
            let floor = sqlx::query_scalar::<_, i64>(
                "SELECT retained_change_floor FROM accounts WHERE id = $1 AND deleted_at IS NULL",
            )
            .bind(account_id)
            .fetch_optional(&state.db)
            .await
            .map_err(database_error)?
            .ok_or_else(not_found)?;
            if token.bootstrap_sequence < floor {
                return Err(ApiError::new(
                    StatusCode::GONE,
                    "page_token_expired",
                    "The catalog cursor expired; restart the complete scan.",
                ));
            }
            (
                token.bootstrap_sequence,
                Some(token.last_cloud_budget_id),
                token.page_size,
                token.issued_at,
            )
        }
    };

    let mut tx = state.db.begin().await.map_err(database_error)?;
    let rows = catalog_rows(
        &mut tx,
        account_id,
        bootstrap_sequence,
        last_id,
        page_size + 1,
    )
    .await?;
    tx.commit().await.map_err(database_error)?;
    let (items, next_page_token) = make_catalog_page(
        state,
        account_id,
        bootstrap_sequence,
        last_id,
        page_size,
        issued_at,
        rows,
    )?;
    Ok(CatalogPage {
        items,
        bootstrap_cursor: None,
        next_page_token,
    })
}

async fn catalog_rows(
    tx: &mut Transaction<'_, Postgres>,
    account_id: Uuid,
    bootstrap_sequence: i64,
    last_id: Option<Uuid>,
    limit: usize,
) -> ApiResult<Vec<CatalogRow>> {
    let limit = i64::try_from(limit).map_err(|_| invalid_request("The page size is too large."))?;
    let rows = match last_id {
        Some(last_id) => sqlx::query_as::<_, CatalogRow>(
            "SELECT cloud_budget_id, portable_budget_id, schema_version, server_version, updated_at \
             FROM budgets WHERE account_id = $1 AND deleted_at IS NULL AND created_seq <= $2 \
             AND EXISTS (SELECT 1 FROM entitlements e WHERE e.account_id = budgets.account_id \
               AND ((e.state IN ('active', 'grace') AND (e.effective_expires_at IS NULL OR e.effective_expires_at > now())) \
                 OR (e.read_access_until IS NOT NULL AND e.read_access_until > now()))) \
             AND cloud_budget_id > $3 ORDER BY cloud_budget_id LIMIT $4",
        )
        .bind(account_id)
        .bind(bootstrap_sequence)
        .bind(last_id)
        .bind(limit)
        .fetch_all(&mut **tx)
        .await,
        None => sqlx::query_as::<_, CatalogRow>(
            "SELECT cloud_budget_id, portable_budget_id, schema_version, server_version, updated_at \
             FROM budgets WHERE account_id = $1 AND deleted_at IS NULL AND created_seq <= $2 \
             AND EXISTS (SELECT 1 FROM entitlements e WHERE e.account_id = budgets.account_id \
               AND ((e.state IN ('active', 'grace') AND (e.effective_expires_at IS NULL OR e.effective_expires_at > now())) \
                 OR (e.read_access_until IS NOT NULL AND e.read_access_until > now()))) \
             ORDER BY cloud_budget_id LIMIT $3",
        )
        .bind(account_id)
        .bind(bootstrap_sequence)
        .bind(limit)
        .fetch_all(&mut **tx)
        .await,
    }
    .map_err(database_error)?;
    Ok(rows)
}

fn make_catalog_page(
    state: &AppState,
    account_id: Uuid,
    bootstrap_sequence: i64,
    last_id: Option<Uuid>,
    page_size: usize,
    issued_at: i64,
    mut rows: Vec<CatalogRow>,
) -> ApiResult<(Vec<BudgetSummary>, Option<String>)> {
    let has_more = rows.len() > page_size;
    if has_more {
        rows.truncate(page_size);
    }
    let next_page_token = if has_more {
        let last_cloud_budget_id = rows
            .last()
            .map(|row| row.cloud_budget_id)
            .or(last_id)
            .ok_or_else(|| ApiError::internal("catalog page was empty while more rows exist"))?;
        Some(
            tokens::sign(
                &state.config.cursor_secret,
                &PageToken {
                    version: 1,
                    kind: "catalog".to_string(),
                    account_id,
                    bootstrap_sequence,
                    last_cloud_budget_id,
                    page_size,
                    issued_at,
                },
            )
            .map_err(ApiError::internal)?,
        )
    } else {
        None
    };
    let items = rows
        .into_iter()
        .map(|row| BudgetSummary {
            cloud_budget_id: row.cloud_budget_id,
            portable_budget_id: row.portable_budget_id,
            schema_version: row.schema_version,
            server_version: row.server_version,
            updated_at: row.updated_at,
        })
        .collect();
    Ok((items, next_page_token))
}

pub async fn create_budget(
    State(state): State<AppState>,
    Extension(AuthenticatedAccount(account_id)): Extension<AuthenticatedAccount>,
    Extension(context): Extension<RequestContext>,
    headers: HeaderMap,
    body: Result<Bytes, BytesRejection>,
) -> Response {
    let body = match bounded_body(body, context) {
        Ok(body) => body,
        Err(response) => return response,
    };
    let idempotency_key = match idempotency_key(&headers) {
        Ok(key) => key,
        Err(error) => return error.into_response(context),
    };
    if let Err(error) = require_json_content_type(&headers) {
        return error.into_response(context);
    }
    let request_digest = idempotency_digest("POST", CREATE_ROUTE, None, &body);
    match create_budget_inner(
        &state,
        account_id,
        idempotency_key,
        request_digest,
        body.to_vec(),
    )
    .await
    {
        Ok((receipt, _replayed)) => receipt_response(StatusCode::CREATED, receipt),
        Err(error) => error.into_response(context),
    }
}

async fn create_budget_inner(
    state: &AppState,
    account_id: Uuid,
    mutation_id: Uuid,
    request_digest: [u8; 32],
    body: Vec<u8>,
) -> ApiResult<(BudgetReceipt, bool)> {
    let mut tx = state.db.begin().await.map_err(database_error)?;
    lock_account(&mut tx, account_id).await?;
    if let Some(receipt) =
        find_receipt(&mut tx, account_id, "POST", CREATE_ROUTE, mutation_id).await?
    {
        if !digest_matches(&receipt.request_digest, &request_digest) {
            return Err(idempotency_reused());
        }
        let receipt = decode_receipt(receipt)?;
        tx.commit().await.map_err(database_error)?;
        return Ok((receipt, true));
    }
    let request: CreateRequest = serde_json::from_slice(&body)
        .map_err(|error| invalid_request(format!("The create request is malformed: {error}")))?;
    let cloud_budget_id = request.cloud_budget_id;
    if cloud_budget_id.is_nil() {
        return Err(invalid_request("cloud_budget_id cannot be empty."));
    }
    let id_in_use = sqlx::query_scalar::<_, bool>(
        "SELECT EXISTS(SELECT 1 FROM budgets WHERE account_id = $1 AND cloud_budget_id = $2)",
    )
    .bind(account_id)
    .bind(cloud_budget_id)
    .fetch_one(&mut *tx)
    .await
    .map_err(database_error)?;
    if id_in_use {
        return Err(ApiError::new(
            StatusCode::CONFLICT,
            "cloud_id_in_use",
            "This cloud budget ID is already reserved.",
        ));
    }
    let snapshot = validate_snapshot(request.envelope.get(), state)?;
    require_write_entitlement(
        &mut tx,
        account_id,
        state.config.dev_entitlement && state.config.dev_account_id == Some(account_id),
    )
    .await?;

    let version = new_server_version();
    let changed_at: DateTime<Utc> = sqlx::query_scalar("SELECT clock_timestamp()")
        .fetch_one(&mut *tx)
        .await
        .map_err(database_error)?;
    let sequence = next_account_sequence(&mut tx, account_id).await?;
    let usage_before = account_storage_usage(&mut tx, account_id).await?;
    sqlx::query(
        "INSERT INTO budgets (account_id, cloud_budget_id, portable_budget_id, schema_version, \
         snapshot_json, current_bytes, server_version, created_seq, updated_at) \
         VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)",
    )
    .bind(account_id)
    .bind(cloud_budget_id)
    .bind(snapshot.portable_budget_id)
    .bind(snapshot.schema_version)
    .bind(&snapshot.json)
    .bind(snapshot.bytes)
    .bind(&version)
    .bind(sequence)
    .bind(changed_at)
    .execute(&mut *tx)
    .await
    .map_err(database_error)?;
    make_quota_room(
        &mut tx,
        account_id,
        state.config.account_storage_limit_bytes,
        usage_before,
    )
    .await?;
    insert_change(
        &mut tx,
        account_id,
        sequence,
        cloud_budget_id,
        "upsert",
        Some(&version),
        Some(snapshot.schema_version),
        changed_at,
        None,
    )
    .await?;

    let receipt = BudgetReceipt {
        cloud_budget_id,
        portable_budget_id: snapshot.portable_budget_id,
        server_version: version.clone(),
        updated_at: changed_at,
    };
    store_receipt(
        &mut tx,
        account_id,
        "POST",
        CREATE_ROUTE,
        mutation_id,
        request_digest,
        StatusCode::CREATED,
        Some(&receipt),
        Some(&version),
        changed_at,
    )
    .await?;
    tx.commit().await.map_err(database_error)?;
    Ok((receipt, false))
}

pub async fn get_budget(
    State(state): State<AppState>,
    Extension(AuthenticatedAccount(account_id)): Extension<AuthenticatedAccount>,
    Extension(context): Extension<RequestContext>,
    Path(budget_id): Path<String>,
    headers: HeaderMap,
) -> Response {
    let budget_id = match parse_uuid(&budget_id, "budget ID") {
        Ok(value) => value,
        Err(error) => return error.into_response(context),
    };
    match get_budget_inner(&state, account_id, budget_id, &headers).await {
        Ok(response) => response,
        Err(error) => error.into_response(context),
    }
}

async fn get_budget_inner(
    state: &AppState,
    account_id: Uuid,
    cloud_budget_id: Uuid,
    headers: &HeaderMap,
) -> ApiResult<Response> {
    let budget = sqlx::query_as::<_, BudgetRow>(
        "SELECT portable_budget_id, snapshot_json, current_bytes, server_version, \
         updated_at, deleted_at, deletion_reason FROM budgets WHERE account_id = $1 AND cloud_budget_id = $2",
    )
    .bind(account_id)
    .bind(cloud_budget_id)
    .fetch_optional(&state.db)
    .await
    .map_err(database_error)?
    .ok_or_else(not_found)?;
    if budget.deleted_at.is_some() {
        return Err(deleted_error(budget.deletion_reason.as_deref()));
    }
    require_read_entitlement(&state.db, account_id).await?;
    if let Some(value) = headers.get("If-None-Match") {
        let value = value
            .to_str()
            .map_err(|_| invalid_request("If-None-Match must be one strong ETag."))?;
        let token = strong_etag_token(value)
            .ok_or_else(|| invalid_request("If-None-Match must be one strong ETag."))?;
        if token == budget.server_version {
            let mut response = StatusCode::NOT_MODIFIED.into_response();
            response
                .headers_mut()
                .insert(ETAG, header_value(&format_etag(&budget.server_version))?);
            return Ok(response);
        }
    }
    let snapshot_json = budget
        .snapshot_json
        .ok_or_else(|| ApiError::internal("live budget has no snapshot"))?;
    let envelope: Value = serde_json::from_str(&snapshot_json).map_err(ApiError::internal)?;
    let result = CloudBudgetResponse {
        cloud_budget_id,
        portable_budget_id: budget.portable_budget_id,
        server_version: budget.server_version.clone(),
        updated_at: budget.updated_at,
        envelope,
    };
    let mut response = Json(result).into_response();
    response
        .headers_mut()
        .insert(ETAG, header_value(&format_etag(&budget.server_version))?);
    Ok(response)
}

pub async fn replace_budget(
    State(state): State<AppState>,
    Extension(AuthenticatedAccount(account_id)): Extension<AuthenticatedAccount>,
    Extension(context): Extension<RequestContext>,
    Path(budget_id): Path<String>,
    headers: HeaderMap,
    body: Result<Bytes, BytesRejection>,
) -> Response {
    let cloud_budget_id = match parse_uuid(&budget_id, "budget ID") {
        Ok(value) => value,
        Err(error) => return error.into_response(context),
    };
    let body = match bounded_body(body, context) {
        Ok(body) => body,
        Err(response) => return response,
    };
    let mutation_id = match idempotency_key(&headers) {
        Ok(key) => key,
        Err(error) => return error.into_response(context),
    };
    let if_match = match required_if_match(&headers) {
        Ok(value) => value,
        Err(error) => return error.into_response(context),
    };
    if let Err(error) = require_json_content_type(&headers) {
        return error.into_response(context);
    }
    let route = format!("/v1/budgets/{cloud_budget_id}");
    let request_digest = idempotency_digest("PUT", &route, Some(if_match), &body);
    match replace_budget_inner(
        &state,
        account_id,
        cloud_budget_id,
        mutation_id,
        request_digest,
        if_match,
        body.to_vec(),
    )
    .await
    {
        Ok((receipt, _replayed)) => receipt_response(StatusCode::OK, receipt),
        Err(error) => error.into_response(context),
    }
}

async fn replace_budget_inner(
    state: &AppState,
    account_id: Uuid,
    cloud_budget_id: Uuid,
    mutation_id: Uuid,
    request_digest: [u8; 32],
    expected_version: &str,
    body: Vec<u8>,
) -> ApiResult<(BudgetReceipt, bool)> {
    let route = format!("/v1/budgets/{cloud_budget_id}");
    let mut tx = state.db.begin().await.map_err(database_error)?;
    lock_account(&mut tx, account_id).await?;
    let mut budget = sqlx::query_as::<_, BudgetRow>(
        "SELECT portable_budget_id, snapshot_json, current_bytes, server_version, \
         updated_at, deleted_at, deletion_reason FROM budgets WHERE account_id = $1 AND cloud_budget_id = $2 FOR UPDATE",
    )
    .bind(account_id)
    .bind(cloud_budget_id)
    .fetch_optional(&mut *tx)
    .await
    .map_err(database_error)?
    .ok_or_else(not_found)?;
    if let Some(receipt) = find_receipt(&mut tx, account_id, "PUT", &route, mutation_id).await? {
        if !digest_matches(&receipt.request_digest, &request_digest) {
            return Err(idempotency_reused());
        }
        let receipt = decode_receipt(receipt)?;
        tx.commit().await.map_err(database_error)?;
        return Ok((receipt, true));
    }
    if budget.deleted_at.is_some() {
        return Err(deleted_error(budget.deletion_reason.as_deref()));
    }
    if budget.server_version != expected_version {
        return Err(version_conflict(&budget.server_version));
    }
    let request: ReplaceRequest = serde_json::from_slice(&body)
        .map_err(|error| invalid_request(format!("The replace request is malformed: {error}")))?;
    let snapshot = validate_snapshot(request.envelope.get(), state)?;
    if budget.portable_budget_id != snapshot.portable_budget_id {
        return Err(ApiError::new(
            StatusCode::UNPROCESSABLE_ENTITY,
            "invalid_snapshot",
            "The snapshot must retain this cloud budget's portable ID.",
        ));
    }
    require_write_entitlement(
        &mut tx,
        account_id,
        state.config.dev_entitlement && state.config.dev_account_id == Some(account_id),
    )
    .await?;

    let now: DateTime<Utc> = sqlx::query_scalar("SELECT clock_timestamp()")
        .fetch_one(&mut *tx)
        .await
        .map_err(database_error)?;
    let usage_before = account_storage_usage(&mut tx, account_id).await?;
    let old_bytes = budget.current_bytes;
    if let Some(old_snapshot) = budget.snapshot_json.take() {
        sqlx::query(
            "INSERT INTO budget_versions (id, account_id, cloud_budget_id, server_version, snapshot_json, byte_size, archived_at) \
             VALUES ($1, $2, $3, $4, $5, $6, $7)",
        )
        .bind(Uuid::new_v4())
        .bind(account_id)
        .bind(cloud_budget_id)
        .bind(&budget.server_version)
        .bind(old_snapshot)
        .bind(old_bytes)
        .bind(now)
        .execute(&mut *tx)
        .await
        .map_err(database_error)?;
    }
    prune_budget_history(&mut tx, account_id, cloud_budget_id, state).await?;
    let version = new_server_version();
    sqlx::query(
        "UPDATE budgets SET schema_version = $3, snapshot_json = $4, current_bytes = $5, \
         server_version = $6, updated_at = $7 WHERE account_id = $1 AND cloud_budget_id = $2",
    )
    .bind(account_id)
    .bind(cloud_budget_id)
    .bind(snapshot.schema_version)
    .bind(&snapshot.json)
    .bind(snapshot.bytes)
    .bind(&version)
    .bind(now)
    .execute(&mut *tx)
    .await
    .map_err(database_error)?;
    make_quota_room(
        &mut tx,
        account_id,
        state.config.account_storage_limit_bytes,
        usage_before,
    )
    .await?;
    let sequence = next_account_sequence(&mut tx, account_id).await?;
    insert_change(
        &mut tx,
        account_id,
        sequence,
        cloud_budget_id,
        "upsert",
        Some(&version),
        Some(snapshot.schema_version),
        now,
        None,
    )
    .await?;

    let receipt = BudgetReceipt {
        cloud_budget_id,
        portable_budget_id: snapshot.portable_budget_id,
        server_version: version.clone(),
        updated_at: now,
    };
    store_receipt(
        &mut tx,
        account_id,
        "PUT",
        &route,
        mutation_id,
        request_digest,
        StatusCode::OK,
        Some(&receipt),
        Some(&version),
        now,
    )
    .await?;
    tx.commit().await.map_err(database_error)?;
    Ok((receipt, false))
}

pub async fn delete_budget(
    State(state): State<AppState>,
    Extension(AuthenticatedAccount(account_id)): Extension<AuthenticatedAccount>,
    Extension(context): Extension<RequestContext>,
    Path(budget_id): Path<String>,
    headers: HeaderMap,
) -> Response {
    let cloud_budget_id = match parse_uuid(&budget_id, "budget ID") {
        Ok(value) => value,
        Err(error) => return error.into_response(context),
    };
    let mutation_id = match idempotency_key(&headers) {
        Ok(key) => key,
        Err(error) => return error.into_response(context),
    };
    let if_match = match required_if_match(&headers) {
        Ok(value) => value,
        Err(error) => return error.into_response(context),
    };
    let route = format!("/v1/budgets/{cloud_budget_id}");
    let request_digest = idempotency_digest("DELETE", &route, Some(if_match), &[]);
    match delete_budget_inner(
        &state,
        account_id,
        cloud_budget_id,
        mutation_id,
        request_digest,
        if_match,
    )
    .await
    {
        Ok(()) => StatusCode::NO_CONTENT.into_response(),
        Err(error) => error.into_response(context),
    }
}

async fn delete_budget_inner(
    state: &AppState,
    account_id: Uuid,
    cloud_budget_id: Uuid,
    mutation_id: Uuid,
    request_digest: [u8; 32],
    expected_version: &str,
) -> ApiResult<()> {
    let route = format!("/v1/budgets/{cloud_budget_id}");
    let mut tx = state.db.begin().await.map_err(database_error)?;
    lock_account(&mut tx, account_id).await?;
    let budget = sqlx::query_as::<_, BudgetRow>(
        "SELECT portable_budget_id, snapshot_json, current_bytes, server_version, \
         updated_at, deleted_at, deletion_reason FROM budgets WHERE account_id = $1 AND cloud_budget_id = $2 FOR UPDATE",
    )
    .bind(account_id)
    .bind(cloud_budget_id)
    .fetch_optional(&mut *tx)
    .await
    .map_err(database_error)?
    .ok_or_else(not_found)?;
    if let Some(receipt) = find_receipt(&mut tx, account_id, "DELETE", &route, mutation_id).await? {
        if !digest_matches(&receipt.request_digest, &request_digest) {
            return Err(idempotency_reused());
        }
        tx.commit().await.map_err(database_error)?;
        return Ok(());
    }
    if budget.deleted_at.is_some() {
        return Err(deleted_error(budget.deletion_reason.as_deref()));
    }
    if budget.server_version != expected_version {
        return Err(version_conflict(&budget.server_version));
    }
    let now: DateTime<Utc> = sqlx::query_scalar("SELECT clock_timestamp()")
        .fetch_one(&mut *tx)
        .await
        .map_err(database_error)?;
    let sequence = next_account_sequence(&mut tx, account_id).await?;
    sqlx::query(
        "UPDATE budgets SET snapshot_json = NULL, current_bytes = 0, deleted_at = $3, \
         deletion_reason = 'user_deleted', updated_at = $3, server_version = $4 WHERE account_id = $1 AND cloud_budget_id = $2",
    )
    .bind(account_id)
    .bind(cloud_budget_id)
    .bind(now)
    .bind(new_server_version())
    .execute(&mut *tx)
    .await
    .map_err(database_error)?;
    sqlx::query("DELETE FROM budget_versions WHERE account_id = $1 AND cloud_budget_id = $2")
        .bind(account_id)
        .bind(cloud_budget_id)
        .execute(&mut *tx)
        .await
        .map_err(database_error)?;
    insert_change(
        &mut tx,
        account_id,
        sequence,
        cloud_budget_id,
        "deleted",
        None,
        None,
        now,
        Some("user_deleted"),
    )
    .await?;
    store_receipt(
        &mut tx,
        account_id,
        "DELETE",
        &route,
        mutation_id,
        request_digest,
        StatusCode::NO_CONTENT,
        None::<&BudgetReceipt>,
        None,
        now,
    )
    .await?;
    tx.commit().await.map_err(database_error)?;
    Ok(())
}

fn receipt_response(status: StatusCode, receipt: BudgetReceipt) -> Response {
    let etag = format_etag(&receipt.server_version);
    let mut response = (status, Json(receipt)).into_response();
    if let Ok(etag) = HeaderValue::from_str(&etag) {
        response.headers_mut().insert(ETAG, etag);
    }
    response
}

async fn lock_account(tx: &mut Transaction<'_, Postgres>, account_id: Uuid) -> ApiResult<()> {
    let exists = sqlx::query_scalar::<_, Uuid>(
        "SELECT id FROM accounts WHERE id = $1 AND deleted_at IS NULL FOR UPDATE",
    )
    .bind(account_id)
    .fetch_optional(&mut **tx)
    .await
    .map_err(database_error)?;
    if exists.is_none() {
        return Err(not_found());
    }
    Ok(())
}

async fn next_account_sequence(
    tx: &mut Transaction<'_, Postgres>,
    account_id: Uuid,
) -> ApiResult<i64> {
    sqlx::query_scalar::<_, i64>(
        "UPDATE accounts SET next_change_seq = next_change_seq + 1 WHERE id = $1 RETURNING next_change_seq",
    )
    .bind(account_id)
    .fetch_one(&mut **tx)
    .await
    .map_err(database_error)
}

async fn require_write_entitlement(
    tx: &mut Transaction<'_, Postgres>,
    account_id: Uuid,
    development_grant: bool,
) -> ApiResult<()> {
    if development_grant {
        return Ok(());
    }
    let allowed = sqlx::query_scalar::<_, bool>(
        "SELECT COALESCE((state IN ('active', 'grace') AND can_write \
         AND (effective_expires_at IS NULL OR effective_expires_at > now())), false) \
         FROM entitlements WHERE account_id = $1",
    )
    .bind(account_id)
    .fetch_optional(&mut **tx)
    .await
    .map_err(database_error)?
    .unwrap_or(false);
    if !allowed {
        return Err(ApiError::new(
            StatusCode::FORBIDDEN,
            "entitlement_required",
            "An active cloud subscription is required to create or update cloud budgets.",
        ));
    }
    Ok(())
}

async fn require_read_entitlement(pool: &sqlx::PgPool, account_id: Uuid) -> ApiResult<()> {
    let allowed = sqlx::query_scalar::<_, bool>(
        "SELECT COALESCE((state IN ('active', 'grace') AND (effective_expires_at IS NULL OR effective_expires_at > now())) \
         OR (read_access_until IS NOT NULL AND read_access_until > now()), false) \
         FROM entitlements WHERE account_id = $1",
    )
    .bind(account_id)
    .fetch_optional(pool)
    .await
    .map_err(database_error)?
    .unwrap_or(false);
    if !allowed {
        return Err(ApiError::new(
            StatusCode::GONE,
            "cloud_retention_expired",
            "This cloud snapshot is no longer available for download.",
        ));
    }
    Ok(())
}

async fn account_storage_usage(
    tx: &mut Transaction<'_, Postgres>,
    account_id: Uuid,
) -> ApiResult<i64> {
    sqlx::query_scalar::<_, i64>(
        "SELECT COALESCE((SELECT SUM(current_bytes)::BIGINT FROM budgets WHERE account_id = $1), 0::BIGINT) \
         + COALESCE((SELECT SUM(byte_size)::BIGINT FROM budget_versions WHERE account_id = $1), 0::BIGINT)",
    )
    .bind(account_id)
    .fetch_one(&mut **tx)
    .await
    .map_err(database_error)
}

async fn make_quota_room(
    tx: &mut Transaction<'_, Postgres>,
    account_id: Uuid,
    limit: i64,
    usage_before: i64,
) -> ApiResult<()> {
    let mut usage_after = account_storage_usage(tx, account_id).await?;
    while usage_after > limit {
        let oldest = sqlx::query_as::<_, (Uuid, i64)>(
            "SELECT id, byte_size FROM budget_versions WHERE account_id = $1 ORDER BY archived_at ASC, id ASC LIMIT 1",
        )
        .bind(account_id)
        .fetch_optional(&mut **tx)
        .await
        .map_err(database_error)?;
        let Some((version_id, _)) = oldest else { break };
        sqlx::query("DELETE FROM budget_versions WHERE id = $1")
            .bind(version_id)
            .execute(&mut **tx)
            .await
            .map_err(database_error)?;
        usage_after = account_storage_usage(tx, account_id).await?;
    }
    if quota_exceeded(limit, usage_before, usage_after) {
        return Err(ApiError::new(
            StatusCode::CONFLICT,
            "quota_exceeded",
            "The account storage limit would be exceeded.",
        )
        .with_details(serde_json::json!({
            "current_usage_bytes": usage_before,
            "projected_usage_bytes": usage_after,
            "limit_bytes": limit
        })));
    }
    Ok(())
}

async fn prune_budget_history(
    tx: &mut Transaction<'_, Postgres>,
    account_id: Uuid,
    cloud_budget_id: Uuid,
    state: &AppState,
) -> ApiResult<()> {
    sqlx::query(
        "DELETE FROM budget_versions WHERE account_id = $1 AND cloud_budget_id = $2 \
         AND archived_at < now() - ($3::double precision * interval '1 day')",
    )
    .bind(account_id)
    .bind(cloud_budget_id)
    .bind(state.config.history_retention_days as f64)
    .execute(&mut **tx)
    .await
    .map_err(database_error)?;
    sqlx::query(
        "DELETE FROM budget_versions WHERE id IN ( \
           SELECT id FROM budget_versions WHERE account_id = $1 AND cloud_budget_id = $2 \
           ORDER BY archived_at DESC, id DESC OFFSET $3 \
         )",
    )
    .bind(account_id)
    .bind(cloud_budget_id)
    .bind(state.config.history_versions_per_budget)
    .execute(&mut **tx)
    .await
    .map_err(database_error)?;
    Ok(())
}

async fn insert_change(
    tx: &mut Transaction<'_, Postgres>,
    account_id: Uuid,
    sequence: i64,
    cloud_budget_id: Uuid,
    kind: &str,
    server_version: Option<&str>,
    schema_version: Option<i32>,
    changed_at: DateTime<Utc>,
    deletion_reason: Option<&str>,
) -> ApiResult<()> {
    sqlx::query(
        "INSERT INTO account_changes (account_id, sequence, cloud_budget_id, kind, server_version, schema_version, changed_at, deletion_reason) \
         VALUES ($1, $2, $3, $4, $5, $6, $7, $8)",
    )
    .bind(account_id)
    .bind(sequence)
    .bind(cloud_budget_id)
    .bind(kind)
    .bind(server_version)
    .bind(schema_version)
    .bind(changed_at)
    .bind(deletion_reason)
    .execute(&mut **tx)
    .await
    .map_err(database_error)?;
    Ok(())
}

async fn find_receipt(
    tx: &mut Transaction<'_, Postgres>,
    account_id: Uuid,
    method: &str,
    route: &str,
    mutation_id: Uuid,
) -> ApiResult<Option<ReceiptRow>> {
    sqlx::query_as::<_, ReceiptRow>(
        "SELECT request_digest, response_status, response_body, server_version FROM mutation_receipts \
         WHERE account_id = $1 AND http_method = $2 AND resource_route = $3 AND mutation_id = $4",
    )
    .bind(account_id)
    .bind(method)
    .bind(route)
    .bind(mutation_id)
    .fetch_optional(&mut **tx)
    .await
    .map_err(database_error)
}

fn decode_receipt(row: ReceiptRow) -> ApiResult<BudgetReceipt> {
    if row.response_status != StatusCode::CREATED.as_u16() as i16
        && row.response_status != StatusCode::OK.as_u16() as i16
    {
        return Err(ApiError::internal(
            "a snapshot receipt has an unexpected status",
        ));
    }
    let body = row
        .response_body
        .ok_or_else(|| ApiError::internal("a snapshot receipt has no response body"))?;
    let receipt: BudgetReceipt = serde_json::from_str(&body).map_err(ApiError::internal)?;
    if row.server_version.as_deref() != Some(receipt.server_version.as_str()) {
        return Err(ApiError::internal(
            "a snapshot receipt has inconsistent version metadata",
        ));
    }
    Ok(receipt)
}

async fn store_receipt<T: Serialize>(
    tx: &mut Transaction<'_, Postgres>,
    account_id: Uuid,
    method: &str,
    route: &str,
    mutation_id: Uuid,
    request_digest: [u8; 32],
    status: StatusCode,
    response: Option<&T>,
    server_version: Option<&str>,
    committed_at: DateTime<Utc>,
) -> ApiResult<()> {
    let response_body = response
        .map(serde_json::to_string)
        .transpose()
        .map_err(ApiError::internal)?;
    sqlx::query(
        "INSERT INTO mutation_receipts (account_id, http_method, resource_route, mutation_id, request_digest, \
         response_status, response_body, server_version, committed_at) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)",
    )
    .bind(account_id)
    .bind(method)
    .bind(route)
    .bind(mutation_id)
    .bind(request_digest.to_vec())
    .bind(status.as_u16() as i16)
    .bind(response_body)
    .bind(server_version)
    .bind(committed_at)
    .execute(&mut **tx)
    .await
    .map_err(database_error)?;
    Ok(())
}

async fn changes(
    State(state): State<AppState>,
    Extension(AuthenticatedAccount(account_id)): Extension<AuthenticatedAccount>,
    Extension(context): Extension<RequestContext>,
    query: Result<Query<ChangesQuery>, QueryRejection>,
) -> Response {
    let Query(query) = match query {
        Ok(query) => query,
        Err(_) => {
            return invalid_request("The change-feed query is malformed.").into_response(context);
        }
    };
    match changes_inner(&state, account_id, query).await {
        Ok(page) => Json(page).into_response(),
        Err(error) => error.into_response(context),
    }
}

#[derive(Deserialize)]
struct ChangesQuery {
    cursor: String,
    page_size: Option<usize>,
}

#[derive(Deserialize, Serialize)]
struct ChangeCursor {
    version: u8,
    kind: String,
    account_id: Uuid,
    sequence: i64,
}

#[derive(Serialize)]
struct ChangePage {
    changes: Vec<ChangeItem>,
    next_cursor: String,
    has_more: bool,
}

#[derive(Serialize)]
#[serde(tag = "kind", rename_all = "lowercase")]
enum ChangeItem {
    Upsert {
        cloud_budget_id: Uuid,
        cursor: String,
        server_version: String,
        schema_version: i32,
        changed_at: DateTime<Utc>,
    },
    Deleted {
        cloud_budget_id: Uuid,
        cursor: String,
        deleted_at: DateTime<Utc>,
        reason: String,
    },
}

#[derive(FromRow)]
struct ChangeRow {
    sequence: i64,
    cloud_budget_id: Uuid,
    kind: String,
    server_version: Option<String>,
    schema_version: Option<i32>,
    changed_at: DateTime<Utc>,
    deletion_reason: Option<String>,
}

async fn changes_inner(
    state: &AppState,
    account_id: Uuid,
    query: ChangesQuery,
) -> ApiResult<ChangePage> {
    let page_size = checked_page_size(query.page_size, state.config.change_page_size)?;
    if query.cursor.len() > 2048 {
        return Err(invalid_request("The change cursor is too long."));
    }
    let cursor: ChangeCursor = tokens::verify(&state.config.cursor_secret, &query.cursor)
        .map_err(|_| invalid_request("The change cursor is invalid."))?;
    if cursor.version != 1
        || cursor.kind != "changes"
        || cursor.account_id != account_id
        || cursor.sequence < 0
    {
        return Err(invalid_request(
            "The change cursor is invalid for this account.",
        ));
    }
    let mut tx = state.db.begin().await.map_err(database_error)?;
    let account = sqlx::query_as::<_, (i64, i64)>(
        "SELECT next_change_seq, retained_change_floor FROM accounts WHERE id = $1 AND deleted_at IS NULL FOR SHARE",
    )
    .bind(account_id)
    .fetch_optional(&mut *tx)
    .await
    .map_err(database_error)?
    .ok_or_else(not_found)?;
    if cursor.sequence > account.0 {
        return Err(invalid_request(
            "The change cursor is ahead of the account feed.",
        ));
    }
    if cursor.sequence < account.1 {
        return Err(ApiError::new(
            StatusCode::GONE,
            "cursor_expired",
            "The change cursor expired; perform a full catalog scan.",
        ));
    }
    let limit =
        i64::try_from(page_size + 1).map_err(|_| invalid_request("The page size is too large."))?;
    let rows = sqlx::query_as::<_, ChangeRow>(
        "SELECT sequence, cloud_budget_id, kind, server_version, schema_version, changed_at, deletion_reason \
         FROM account_changes WHERE account_id = $1 AND sequence > $2 ORDER BY sequence LIMIT $3",
    )
    .bind(account_id)
    .bind(cursor.sequence)
    .bind(limit)
    .fetch_all(&mut *tx)
    .await
    .map_err(database_error)?;
    tx.commit().await.map_err(database_error)?;
    let has_more = rows.len() > page_size;
    let mut rows = rows;
    if has_more {
        rows.truncate(page_size);
    }
    let mut changes = Vec::with_capacity(rows.len());
    let mut next_sequence = cursor.sequence;
    for row in rows {
        next_sequence = row.sequence;
        let item_cursor = encode_change_cursor(state, account_id, row.sequence)?;
        let item = match row.kind.as_str() {
            "upsert" => ChangeItem::Upsert {
                cloud_budget_id: row.cloud_budget_id,
                cursor: item_cursor,
                server_version: row
                    .server_version
                    .ok_or_else(|| ApiError::internal("upsert feed row has no version"))?,
                schema_version: row
                    .schema_version
                    .ok_or_else(|| ApiError::internal("upsert feed row has no schema"))?,
                changed_at: row.changed_at,
            },
            "deleted" => ChangeItem::Deleted {
                cloud_budget_id: row.cloud_budget_id,
                cursor: item_cursor,
                deleted_at: row.changed_at,
                reason: row
                    .deletion_reason
                    .ok_or_else(|| ApiError::internal("delete feed row has no reason"))?,
            },
            _ => {
                return Err(ApiError::internal(
                    "change feed contains an unknown event kind",
                ));
            }
        };
        changes.push(item);
    }
    Ok(ChangePage {
        changes,
        next_cursor: encode_change_cursor(state, account_id, next_sequence)?,
        has_more,
    })
}

fn encode_change_cursor(state: &AppState, account_id: Uuid, sequence: i64) -> ApiResult<String> {
    tokens::sign(
        &state.config.cursor_secret,
        &ChangeCursor {
            version: 1,
            kind: "changes".to_string(),
            account_id,
            sequence,
        },
    )
    .map_err(ApiError::internal)
}

fn validate_snapshot(raw: &str, state: &AppState) -> ApiResult<ValidatedEnvelope> {
    envelope::validate(raw, state.config.max_snapshot_bytes)
}

fn checked_page_size(requested: Option<usize>, default: usize) -> ApiResult<usize> {
    let size = requested.unwrap_or(default);
    if !(1..=100).contains(&size) {
        return Err(invalid_request("page_size must be between 1 and 100."));
    }
    Ok(size)
}

fn bounded_body(
    body: Result<Bytes, BytesRejection>,
    context: RequestContext,
) -> Result<Bytes, Response> {
    body.map_err(|rejection| {
        let status = rejection.into_response().status();
        if status == StatusCode::PAYLOAD_TOO_LARGE {
            ApiError::new(
                StatusCode::PAYLOAD_TOO_LARGE,
                "snapshot_too_large",
                "The request body exceeds the configured limit.",
            )
            .into_response(context)
        } else {
            invalid_request("The request body could not be read.").into_response(context)
        }
    })
}

fn require_json_content_type(headers: &HeaderMap) -> ApiResult<()> {
    let is_json = headers
        .get(CONTENT_TYPE)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.split(';').next())
        .is_some_and(|value| value.trim().eq_ignore_ascii_case("application/json"));
    if !is_json {
        return Err(invalid_request("Content-Type must be application/json."));
    }
    if headers.get("Content-Encoding").is_some_and(|value| {
        !value
            .to_str()
            .is_ok_and(|encoding| encoding.eq_ignore_ascii_case("identity"))
    }) {
        return Err(invalid_request(
            "Compressed request bodies are not supported.",
        ));
    }
    Ok(())
}

fn idempotency_key(headers: &HeaderMap) -> ApiResult<Uuid> {
    let value = headers
        .get("Idempotency-Key")
        .and_then(|value| value.to_str().ok())
        .ok_or_else(|| invalid_request("Idempotency-Key is required and must be a UUID."))?;
    let key =
        Uuid::parse_str(value).map_err(|_| invalid_request("Idempotency-Key must be a UUID."))?;
    if key.is_nil() {
        return Err(invalid_request("Idempotency-Key cannot be empty."));
    }
    Ok(key)
}

fn required_if_match(headers: &HeaderMap) -> ApiResult<&str> {
    let value = headers
        .get("If-Match")
        .and_then(|value| value.to_str().ok())
        .ok_or_else(|| invalid_request("If-Match is required and must be a strong ETag."))?;
    strong_etag_token(value).ok_or_else(|| invalid_request("If-Match must be one strong ETag."))
}

fn strong_etag_token(value: &str) -> Option<&str> {
    if value.len() < 3 || value.len() > 128 || !value.starts_with('"') || !value.ends_with('"') {
        return None;
    }
    let token = &value[1..value.len() - 1];
    token
        .bytes()
        .all(|byte| byte.is_ascii_alphanumeric() || byte == b'_' || byte == b'-')
        .then_some(token)
}

fn parse_uuid(value: &str, label: &str) -> ApiResult<Uuid> {
    Uuid::parse_str(value).map_err(|_| invalid_request(format!("The {label} is not a UUID.")))
}

fn idempotency_digest(method: &str, route: &str, if_match: Option<&str>, body: &[u8]) -> [u8; 32] {
    let mut digest = Sha256::new();
    digest.update(method.as_bytes());
    digest.update([0]);
    digest.update(route.as_bytes());
    digest.update([0]);
    if let Some(if_match) = if_match {
        digest.update(if_match.as_bytes());
    }
    digest.update([0]);
    digest.update(body);
    digest.finalize().into()
}

fn digest_matches(stored: &[u8], expected: &[u8; 32]) -> bool {
    stored == expected
}

fn new_server_version() -> String {
    Uuid::new_v4().simple().to_string()
}

fn format_etag(version: &str) -> String {
    format!("\"{version}\"")
}

fn header_value(value: &str) -> ApiResult<HeaderValue> {
    HeaderValue::from_str(value).map_err(ApiError::internal)
}

fn not_found() -> ApiError {
    ApiError::new(
        StatusCode::NOT_FOUND,
        "not_found",
        "The requested cloud budget was not found.",
    )
}

fn deleted_error(reason: Option<&str>) -> ApiError {
    if reason == Some("retention_expired") {
        ApiError::new(
            StatusCode::GONE,
            "cloud_retention_expired",
            "The cloud budget passed its retention deadline.",
        )
    } else {
        ApiError::new(
            StatusCode::GONE,
            "resource_deleted",
            "This cloud budget was deleted and cannot be recreated.",
        )
    }
}

fn idempotency_reused() -> ApiError {
    ApiError::new(
        StatusCode::CONFLICT,
        "idempotency_key_reused",
        "This idempotency key was already used for a different request.",
    )
}

fn version_conflict(current_version: &str) -> ApiError {
    ApiError::new(
        StatusCode::CONFLICT,
        "version_conflict",
        "The cloud budget changed since the supplied version.",
    )
    .with_details(serde_json::json!({ "current_server_version": current_version }))
}

// After recovery history is evicted, a reduced allowance must still permit
// writes that do not increase the account's actual combined storage usage.
fn quota_exceeded(limit: i64, usage_before: i64, usage_after: i64) -> bool {
    usage_after > limit && usage_after > usage_before
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn quota_accounts_for_archived_snapshots() {
        assert!(quota_exceeded(100, 150, 200));
        assert!(quota_exceeded(100, 90, 101));
        assert!(!quota_exceeded(100, 150, 150));
        assert!(!quota_exceeded(100, 150, 120));
        assert!(!quota_exceeded(100, 90, 100));
    }
}
