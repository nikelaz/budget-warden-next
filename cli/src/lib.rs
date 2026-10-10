pub mod args;
mod batch;
mod commands;
pub mod config;
pub mod error;
pub mod protocol;
pub mod storage;
pub mod util;

pub use args::{Cli, OutputFormat};
use protocol::{Envelope, Meta};
use serde_json::Value;

pub struct Outcome {
    pub envelope: Envelope,
}

pub fn success(command: &str, data: Value, meta: Option<Meta>) -> Outcome {
    Outcome {
        envelope: Envelope {
            protocol_version: protocol::PROTOCOL_VERSION,
            ok: true,
            data,
            error: None,
            meta: meta.or_else(|| Some(Meta::command(command))),
        },
    }
}

pub fn error_envelope(command: &str, error: error::ApiError) -> Envelope {
    Envelope {
        protocol_version: protocol::PROTOCOL_VERSION,
        ok: false,
        data: Value::Null,
        error: Some(error),
        meta: Some(Meta::command(command)),
    }
}

pub fn dispatch(cli: Cli) -> Result<Outcome, (String, error::ApiError)> {
    let command = commands::command_name(&cli.command);
    commands::dispatch(cli).map_err(|error| (command, error))
}

pub fn render_text(outcome: &Outcome, currency: Option<&str>) -> String {
    let value = &outcome.envelope.data;
    match value {
        Value::String(value) => value.clone(),
        Value::Array(rows) => rows
            .iter()
            .map(|row| match row {
                Value::Object(object) => object
                    .iter()
                    .map(|(key, value)| {
                        format!("{key}: {}", display_value(Some(key), value, currency))
                    })
                    .collect::<Vec<_>>()
                    .join("  "),
                _ => display_value(None, row, currency),
            })
            .collect::<Vec<_>>()
            .join("\n"),
        Value::Object(object) => object
            .iter()
            .map(|(key, value)| format!("{key}: {}", display_value(Some(key), value, currency)))
            .collect::<Vec<_>>()
            .join("\n"),
        _ => display_value(None, value, currency),
    }
}

fn display_value(key: Option<&str>, value: &Value, currency: Option<&str>) -> String {
    match value {
        Value::String(value) if is_money_key(key.unwrap_or_default()) && is_decimal_text(value) => {
            currency
                .map(|currency| format!("{value} {currency}"))
                .unwrap_or_else(|| value.clone())
        }
        Value::String(value) => value.clone(),
        Value::Null => "—".to_string(),
        Value::Array(values) => values
            .iter()
            .map(|value| display_value(None, value, currency))
            .collect::<Vec<_>>()
            .join(", "),
        Value::Object(values) => values
            .iter()
            .map(|(key, value)| format!("{key}: {}", display_value(Some(key), value, currency)))
            .collect::<Vec<_>>()
            .join("; "),
        _ => value.to_string(),
    }
}

fn is_money_key(key: &str) -> bool {
    key == "amount"
        || key.ends_with("_amount")
        || matches!(
            key,
            "income"
                | "planned_spending"
                | "actual_spending"
                | "planned_savings"
                | "planned_allocation"
                | "actual_allocation"
                | "left_to_budget"
        )
}

fn is_decimal_text(value: &str) -> bool {
    let value = value.strip_prefix('-').unwrap_or(value);
    let mut parts = value.split('.');
    matches!((parts.next(), parts.next(), parts.next()), (Some(whole), Some(fraction), None) if !whole.is_empty() && whole.bytes().all(|byte| byte.is_ascii_digit()) && fraction.len() == 2 && fraction.bytes().all(|byte| byte.is_ascii_digit()))
}
