use serde::Serialize;
use serde_json::{Value, json};

#[derive(Debug, Clone, Serialize)]
pub struct ApiError {
    pub code: String,
    pub message: String,
    pub details: Value,
    pub retryable: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub commit_outcome: Option<String>,
    #[serde(skip)]
    pub exit_code: u8,
}

impl ApiError {
    pub fn new(code: &str, message: impl Into<String>, exit_code: u8) -> Self {
        Self {
            code: code.to_string(),
            message: message.into(),
            details: Value::Null,
            retryable: false,
            commit_outcome: None,
            exit_code,
        }
    }

    pub fn details(mut self, details: Value) -> Self {
        self.details = details;
        self
    }
    pub fn retryable(mut self, retryable: bool) -> Self {
        self.retryable = retryable;
        self
    }
    pub fn outcome(mut self, outcome: &str) -> Self {
        self.commit_outcome = Some(outcome.to_string());
        self
    }
}

pub fn usage_error(message: impl Into<String>) -> ApiError {
    ApiError::new("usage_error", message, 2)
}

pub fn missing_file(path: impl Into<String>) -> ApiError {
    ApiError::new("file_not_found", "Budget file was not found", 3)
        .details(json!({"path": path.into()}))
}

pub fn missing_entity(kind: &str, id: impl Into<String>) -> ApiError {
    ApiError::new("entity_not_found", format!("{kind} was not found"), 3)
        .details(json!({"entity": kind, "id": id.into()}))
}

pub fn io_error(error: std::io::Error, path: impl Into<String>) -> ApiError {
    let code = match error.kind() {
        std::io::ErrorKind::PermissionDenied => "permission_denied",
        std::io::ErrorKind::NotFound => "file_not_found",
        _ => "io_error",
    };
    ApiError::new(
        code,
        error.to_string(),
        if error.kind() == std::io::ErrorKind::NotFound {
            3
        } else {
            6
        },
    )
    .details(json!({"path": path.into(), "kind": format!("{:?}", error.kind())}))
}

pub fn core_error(code: &str, message: impl Into<String>) -> ApiError {
    let message = message.into();
    ApiError::new(code, message.clone(), 4).details(json!({"operation_error": message}))
}
