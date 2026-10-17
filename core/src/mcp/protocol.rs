/*
 * Budget Warden
 * Copyright (c) 2026 Lazarov & Co EOOD
 * Author: Nikola Lazarov
 *
 * Licensed under the Source-Available Educational License.
 * See the LICENSE file in the project root for full terms.
 */

//! JSON-RPC 2.0 message handling for MCP.

use serde_json::{Value, json};

use super::http::{Request, Response};
use super::tools::{self, BudgetService};

pub(super) const SUPPORTED_PROTOCOL_VERSIONS: [&str; 3] = ["2025-06-18", "2025-03-26", "2024-11-05"];

const PARSE_ERROR: i64 = -32700;
const INVALID_REQUEST: i64 = -32600;
const METHOD_NOT_FOUND: i64 = -32601;
const INVALID_PARAMS: i64 = -32602;

const INSTRUCTIONS: &str = "Budget Warden budgets are local `.budget` documents made of categories \
(income, expenses, savings, debt) that hold transactions. Start with `list_budgets` and pass a \
budget's `budget` value (or its id) to the other tools. Amounts are decimal strings in the \
budget's currency, such as \"12.50\"; they are never negative. Dates use YYYY-MM-DD. Changes are \
saved immediately and the Budget Warden app reloads them.";

pub(super) fn handle_post(request: &Request, service: &BudgetService) -> Response {
    if !request
        .header("content-type")
        .is_some_and(|value| value.to_ascii_lowercase().contains("application/json"))
    {
        return Response::text(415, "Content-Type must be application/json");
    }

    let message: Value = match serde_json::from_slice(&request.body) {
        Ok(message) => message,
        Err(error) => {
            return Response::json(
                400,
                &error_response(Value::Null, PARSE_ERROR, &format!("Parse error: {error}")),
            );
        }
    };

    let batch = message.is_array();
    let replies: Vec<Value> = match message {
        Value::Array(messages) if messages.is_empty() => {
            vec![error_response(Value::Null, INVALID_REQUEST, "Empty batch")]
        }
        Value::Array(messages) => messages
            .into_iter()
            .filter_map(|message| handle_message(message, service))
            .collect(),
        Value::Object(_) => handle_message(message, service).into_iter().collect(),
        _ => vec![error_response(Value::Null, INVALID_REQUEST, "Invalid request")],
    };

    match (replies.len(), batch) {
        (0, _) => Response::empty(202),
        (1, false) => Response::json(200, &replies[0]),
        _ => Response::json(200, &Value::Array(replies)),
    }
}

/// Handles one JSON-RPC message and returns its response, if it needs one.
pub(super) fn handle_message(message: Value, service: &BudgetService) -> Option<Value> {
    let Value::Object(object) = message else {
        return Some(error_response(Value::Null, INVALID_REQUEST, "Invalid request"));
    };
    let id = object.get("id").cloned();
    let Some(method) = object.get("method").and_then(Value::as_str) else {
        // A response or malformed message. Clients do not answer server
        // requests here because the server never sends any.
        return id.map(|id| error_response(id, INVALID_REQUEST, "Missing method"));
    };
    let Some(id) = id else {
        // Notifications such as notifications/initialized need no reply.
        return None;
    };
    let params = object.get("params").cloned().unwrap_or(Value::Null);

    let result = match method {
        "initialize" => Ok(initialize(&params)),
        "ping" => Ok(json!({})),
        "tools/list" => Ok(json!({ "tools": tools::definitions() })),
        "tools/call" => call_tool(&params, service),
        "resources/list" => Ok(json!({ "resources": [] })),
        "resources/templates/list" => Ok(json!({ "resourceTemplates": [] })),
        "prompts/list" => Ok(json!({ "prompts": [] })),
        _ => Err((METHOD_NOT_FOUND, format!("Method not found: {method}"))),
    };

    Some(match result {
        Ok(result) => json!({ "jsonrpc": "2.0", "id": id, "result": result }),
        Err((code, message)) => error_response(id, code, &message),
    })
}

fn initialize(params: &Value) -> Value {
    let requested = params.get("protocolVersion").and_then(Value::as_str);
    let version = requested
        .filter(|version| SUPPORTED_PROTOCOL_VERSIONS.contains(version))
        .unwrap_or(SUPPORTED_PROTOCOL_VERSIONS[0]);
    json!({
        "protocolVersion": version,
        "capabilities": { "tools": { "listChanged": false } },
        "serverInfo": {
            "name": "budget-warden",
            "title": "Budget Warden",
            "version": env!("CARGO_PKG_VERSION"),
        },
        "instructions": INSTRUCTIONS,
    })
}

fn call_tool(params: &Value, service: &BudgetService) -> Result<Value, (i64, String)> {
    let name = params
        .get("name")
        .and_then(Value::as_str)
        .ok_or((INVALID_PARAMS, "tools/call requires a tool name".to_string()))?;
    let arguments = match params.get("arguments") {
        None | Some(Value::Null) => Value::Object(Default::default()),
        Some(arguments @ Value::Object(_)) => arguments.clone(),
        Some(_) => return Err((INVALID_PARAMS, "Tool arguments must be an object".to_string())),
    };
    if !tools::definitions()
        .iter()
        .any(|tool| tool["name"].as_str() == Some(name))
    {
        return Err((INVALID_PARAMS, format!("Unknown tool: {name}")));
    }

    Ok(match service.call(name, &arguments) {
        Ok(value) => json!({
            "content": [{
                "type": "text",
                "text": serde_json::to_string_pretty(&value).unwrap_or_default(),
            }],
            "structuredContent": value,
            "isError": false,
        }),
        Err(message) => json!({
            "content": [{ "type": "text", "text": message }],
            "isError": true,
        }),
    })
}

fn error_response(id: Value, code: i64, message: &str) -> Value {
    json!({
        "jsonrpc": "2.0",
        "id": id,
        "error": { "code": code, "message": message },
    })
}
