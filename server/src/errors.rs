use axum::{
    Json,
    http::StatusCode,
    response::{IntoResponse, Response},
};
use serde::Serialize;
use serde_json::Value;
use uuid::Uuid;

#[derive(Clone, Copy, Debug)]
pub struct RequestContext {
    pub id: Uuid,
}

#[derive(Debug)]
pub struct ApiError {
    pub status: StatusCode,
    pub code: &'static str,
    pub detail: String,
    pub details: Option<Value>,
}

#[derive(Serialize)]
struct ApiProblem {
    #[serde(rename = "type")]
    problem_type: String,
    title: &'static str,
    status: u16,
    code: &'static str,
    request_id: Uuid,
    detail: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    details: Option<Value>,
}

impl ApiError {
    pub fn new(status: StatusCode, code: &'static str, detail: impl Into<String>) -> Self {
        Self {
            status,
            code,
            detail: detail.into(),
            details: None,
        }
    }

    pub fn with_details(mut self, details: Value) -> Self {
        self.details = Some(details);
        self
    }

    pub fn internal(error: impl std::fmt::Display) -> Self {
        tracing::error!(error = %error, "cloud server operation failed");
        Self::new(
            StatusCode::INTERNAL_SERVER_ERROR,
            "internal_error",
            "The service could not complete the request.",
        )
    }

    pub fn into_response(self, context: RequestContext) -> Response {
        let title = match self.status {
            StatusCode::BAD_REQUEST => "Invalid request",
            StatusCode::UNAUTHORIZED => "Authentication required",
            StatusCode::FORBIDDEN => "Access denied",
            StatusCode::NOT_FOUND => "Not found",
            StatusCode::GONE => "Resource unavailable",
            StatusCode::CONFLICT => "Conflict",
            StatusCode::PAYLOAD_TOO_LARGE => "Request too large",
            StatusCode::UNPROCESSABLE_ENTITY => "Invalid snapshot",
            StatusCode::UPGRADE_REQUIRED => "Protocol upgrade required",
            StatusCode::TOO_MANY_REQUESTS => "Rate limited",
            _ => "Service error",
        };
        let problem = ApiProblem {
            problem_type: "about:blank".to_string(),
            title,
            status: self.status.as_u16(),
            code: self.code,
            request_id: context.id,
            detail: self.detail,
            details: self.details,
        };
        let mut response = (self.status, Json(problem)).into_response();
        response.headers_mut().insert(
            axum::http::header::CONTENT_TYPE,
            "application/problem+json"
                .parse()
                .expect("static header is valid"),
        );
        response
    }
}

pub fn invalid_request(detail: impl Into<String>) -> ApiError {
    ApiError::new(StatusCode::BAD_REQUEST, "invalid_request", detail)
}

pub fn database_error(error: sqlx::Error) -> ApiError {
    ApiError::internal(error)
}

pub type ApiResult<T> = Result<T, ApiError>;
