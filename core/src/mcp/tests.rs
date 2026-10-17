use std::collections::BTreeMap;
use std::io::{Read, Write};
use std::net::TcpStream;
use std::sync::{Arc, Mutex};

use serde_json::{Value, json};
use uuid::Uuid;

use super::protocol::handle_message;
use super::tools::{BudgetService, budget_file_name};
use super::*;
use crate::app_state::initialize_core;

#[derive(Default)]
struct MemoryHost {
    files: Mutex<BTreeMap<String, String>>,
    changed: Mutex<Vec<String>>,
    shown: Mutex<Vec<String>>,
}

impl BWMcpHost for Arc<MemoryHost> {
    fn list_budgets(&self) -> Vec<BWMcpBudgetLocation> {
        self.files
            .lock()
            .unwrap()
            .keys()
            .map(|location| BWMcpBudgetLocation {
                location: location.clone(),
                is_open: false,
            })
            .collect()
    }

    fn read_budget_file(&self, location: String) -> Result<String, String> {
        self.files
            .lock()
            .unwrap()
            .get(&location)
            .cloned()
            .ok_or_else(|| format!("missing {location}"))
    }

    fn write_budget_file(&self, location: String, json: String) -> Result<(), String> {
        self.files.lock().unwrap().insert(location, json);
        Ok(())
    }

    fn create_budget_file(&self, file_name: String, json: String) -> Result<String, String> {
        let location = format!("/budgets/{file_name}");
        self.files.lock().unwrap().insert(location.clone(), json);
        Ok(location)
    }

    fn budget_did_change(&self, location: String) {
        self.changed.lock().unwrap().push(location);
    }

    fn show_budget(&self, location: String) -> Result<(), String> {
        self.shown.lock().unwrap().push(location);
        Ok(())
    }

    fn currency_code(&self) -> String {
        "EUR".to_string()
    }
}

fn service() -> (Arc<MemoryHost>, BudgetService) {
    let _ = initialize_core(Uuid::from_u128(0x3C9));
    let host = Arc::new(MemoryHost::default());
    let service = BudgetService::new(Arc::new(host.clone()));
    (host, service)
}

fn call(service: &BudgetService, name: &str, arguments: Value) -> Value {
    let response = handle_message(
        json!({
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": { "name": name, "arguments": arguments },
        }),
        service,
    )
    .expect("tool calls are requests");
    let result = &response["result"];
    assert_eq!(result["isError"], json!(false), "{name} failed: {response}");
    result["structuredContent"].clone()
}

fn call_error(service: &BudgetService, name: &str, arguments: Value) -> String {
    let response = handle_message(
        json!({
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": { "name": name, "arguments": arguments },
        }),
        service,
    )
    .unwrap();
    assert_eq!(response["result"]["isError"], json!(true), "{response}");
    response["result"]["content"][0]["text"].as_str().unwrap().to_string()
}

#[test]
fn initialize_negotiates_version_and_lists_tools() {
    let (_, service) = service();
    let response = handle_message(
        json!({
            "jsonrpc": "2.0",
            "id": "init",
            "method": "initialize",
            "params": { "protocolVersion": "2025-03-26", "capabilities": {}, "clientInfo": { "name": "t", "version": "1" } },
        }),
        &service,
    )
    .unwrap();
    assert_eq!(response["id"], json!("init"));
    assert_eq!(response["result"]["protocolVersion"], json!("2025-03-26"));
    assert!(response["result"]["capabilities"]["tools"].is_object());

    assert!(
        handle_message(json!({ "jsonrpc": "2.0", "method": "notifications/initialized" }), &service)
            .is_none()
    );

    let tools = handle_message(json!({ "jsonrpc": "2.0", "id": 2, "method": "tools/list" }), &service).unwrap();
    let names: Vec<&str> = tools["result"]["tools"]
        .as_array()
        .unwrap()
        .iter()
        .map(|tool| tool["name"].as_str().unwrap())
        .collect();
    for expected in ["create_budget", "create_category", "update_transaction", "get_report"] {
        assert!(names.contains(&expected), "missing {expected}");
    }

    let unknown = handle_message(json!({ "jsonrpc": "2.0", "id": 3, "method": "nope" }), &service).unwrap();
    assert_eq!(unknown["error"]["code"], json!(-32601));
}

#[test]
fn tools_manage_a_budget_end_to_end() {
    let (host, service) = service();

    let created = call(&service, "create_budget", json!({ "title": "March 2026", "template_id": "empty", "open_in_app": true }));
    let budget = created["budget"].as_str().unwrap().to_string();
    assert_eq!(budget, "/budgets/March 2026.budget");
    assert_eq!(host.shown.lock().unwrap().as_slice(), std::slice::from_ref(&budget));

    let listed = call(&service, "list_budgets", json!({}));
    assert_eq!(listed["currency"], json!("EUR"));
    assert_eq!(listed["budgets"][0]["title"], json!("March 2026"));

    let salary = call(&service, "create_category", json!({ "budget": budget, "title": "Salary", "type": "income", "planned_amount": "3000" }));
    let food = call(&service, "create_category", json!({ "budget": budget, "title": "Food", "type": "expenses", "planned_amount": 400.5 }));
    let rent = call(&service, "create_category", json!({ "budget": budget, "title": "Rent", "type": "expenses", "planned_amount": "1200.00", "position": 0 }));
    assert_eq!(food["planned_amount"], json!("400.50"));
    assert_eq!(rent["position"], json!(0));

    let expenses = call(&service, "list_categories", json!({ "budget": budget, "type": "expenses" }));
    let titles: Vec<&str> = expenses["categories"].as_array().unwrap().iter().map(|c| c["title"].as_str().unwrap()).collect();
    assert_eq!(titles, ["Rent", "Food"]);

    let groceries = call(&service, "create_transaction", json!({
        "budget": budget, "category_id": food["id"], "title": "Groceries", "amount": "45.20", "date": "2026-03-04",
    }));
    call(&service, "create_transaction", json!({
        "budget": budget, "category_id": food["id"], "title": "Bakery", "amount": "4.80", "date": "2026-03-05", "description": "bread",
    }));
    let category = call(&service, "get_category", json!({ "budget": budget, "category_id": food["id"] }));
    assert_eq!(category["actual_amount"], json!("50.00"));
    assert_eq!(category["transactions"][0]["title"], json!("Bakery"));

    let moved = call(&service, "update_transaction", json!({
        "budget": budget, "transaction_id": groceries["id"], "amount": "40", "category_id": rent["id"], "title": "Groceries (fixed)",
    }));
    assert_eq!(moved["category_id"], rent["id"]);
    assert_eq!(moved["amount"], json!("40.00"));
    assert_eq!(moved["date"], json!("2026-03-04"));

    let search = call(&service, "list_transactions", json!({ "budget": budget, "search": "BREAD" }));
    assert_eq!(search["total_count"], json!(1));
    let march = call(&service, "list_transactions", json!({ "budget": budget, "from_date": "2026-03-05", "to_date": "2026-03-31" }));
    assert_eq!(march["transactions"][0]["title"], json!("Bakery"));

    let updated = call(&service, "update_category", json!({ "budget": budget, "category_id": food["id"], "type": "savings", "title": "Food fund", "position": 0 }));
    assert_eq!(updated["type"], json!("savings"));
    assert_eq!(updated["title"], json!("Food fund"));

    let report = call(&service, "get_report", json!({ "budget": budget }));
    assert_eq!(report["totals"]["income"], json!("3000.00"));

    let renamed = call(&service, "rename_budget", json!({ "budget": created["id"], "title": "March" }));
    assert_eq!(renamed["title"], json!("March"));

    call(&service, "delete_transaction", json!({ "budget": budget, "transaction_id": moved["id"] }));
    let deleted = call(&service, "delete_category", json!({ "budget": budget, "category_id": salary["id"] }));
    assert_eq!(deleted["title"], json!("Salary"));

    let snapshot = call(&service, "get_budget", json!({ "budget": budget, "include_transactions": true }));
    assert_eq!(snapshot["title"], json!("March"));
    assert_eq!(snapshot["categories"].as_array().unwrap().len(), 2);
    assert_eq!(snapshot["totals"]["income"], json!("0.00"));

    // The stored document stays a valid, decodable budget.
    let stored = host.read_budget_file(budget.clone()).unwrap();
    let decoded = crate::codec::decode_budget(&stored, budget.clone()).unwrap();
    assert_eq!(decoded.title, "March");
    assert!(host.changed.lock().unwrap().iter().all(|location| *location == budget));

    let copy = call(&service, "create_budget", json!({ "title": "April 2026", "copy_from": budget }));
    assert_eq!(copy["categories"].as_array().unwrap().len(), 2);
    assert_eq!(copy["categories"][0]["transaction_count"], json!(0));
}

#[test]
fn tools_report_invalid_input_as_tool_errors() {
    let (_, service) = service();
    let created = call(&service, "create_budget", json!({ "title": "Errors" }));
    let budget = created["budget"].as_str().unwrap();
    let category = &created["categories"][0]["id"];

    assert!(call_error(&service, "get_budget", json!({ "budget": "nope" })).contains("Unknown budget"));
    assert!(call_error(&service, "create_transaction", json!({ "budget": budget, "category_id": category, "title": "x", "amount": "-1" })).contains("amount"));
    assert!(call_error(&service, "create_transaction", json!({ "budget": budget, "category_id": category, "title": "x", "amount": "1", "date": "03/04/2026" })).contains("YYYY-MM-DD"));
    assert!(call_error(&service, "create_category", json!({ "budget": budget, "title": "x", "type": "fun" })).contains("income"));
    assert!(call_error(&service, "update_category", json!({ "budget": budget, "category_id": category, "position": 99 })).contains("out of range"));
}

#[test]
fn budget_file_names_are_safe() {
    assert_eq!(budget_file_name("Home/Work: 2026"), "Home-Work- 2026.budget");
    assert_eq!(budget_file_name("  .. "), "Untitled Budget.budget");
}

fn http_post(port: u16, path: &str, body: &str) -> (u16, String) {
    let mut stream = TcpStream::connect(("127.0.0.1", port)).unwrap();
    write!(
        stream,
        "POST {path} HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nAccept: application/json, text/event-stream\r\nConnection: close\r\nContent-Length: {}\r\n\r\n{body}",
        body.len()
    )
    .unwrap();
    let mut response = String::new();
    stream.read_to_string(&mut response).unwrap();
    let status = response[9..12].parse().unwrap();
    let body = response.split_once("\r\n\r\n").map(|(_, body)| body.to_string()).unwrap_or_default();
    (status, body)
}

#[test]
fn server_serves_streamable_http_behind_its_token() {
    let _ = initialize_core(Uuid::from_u128(0x3C9));
    let host = Arc::new(MemoryHost::default());
    let server = BWMcpServer::new();
    let token = generate_mcp_token();
    let status = server
        .start(
            Box::new(host.clone()),
            BWMcpServerConfig { port: 0, token: token.clone(), allow_network: false },
        )
        .unwrap_or_else(|_| {
            // The default port may be taken on a shared machine.
            server
                .start(
                    Box::new(host.clone()),
                    BWMcpServerConfig { port: 38_765, token: token.clone(), allow_network: false },
                )
                .unwrap()
        });
    assert!(status.running);
    let port = status.port as u16;
    assert_eq!(status.url.as_deref(), Some(format!("http://127.0.0.1:{port}/{token}/mcp").as_str()));

    let (code, _) = http_post(port, "/wrong/mcp", "{}");
    assert_eq!(code, 404);

    let path = format!("/{token}/mcp");
    let (code, body) = http_post(port, &path, r#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#);
    assert_eq!(code, 200);
    let body: Value = serde_json::from_str(&body).unwrap();
    assert_eq!(body["result"]["serverInfo"]["name"], json!("budget-warden"));

    let (code, _) = http_post(port, &path, r#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#);
    assert_eq!(code, 202);

    let (code, body) = http_post(port, &path, r#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"create_budget","arguments":{"title":"Over HTTP"}}}"#);
    assert_eq!(code, 200);
    assert!(body.contains("Over HTTP"));
    assert_eq!(host.files.lock().unwrap().len(), 1);

    server.stop();
    assert!(!server.status().running);
    assert!(TcpStream::connect(("127.0.0.1", port)).is_err());
}

#[test]
fn server_rejects_weak_tokens() {
    let server = BWMcpServer::new();
    let error = server
        .start(
            Box::new(Arc::new(MemoryHost::default())),
            BWMcpServerConfig { port: 0, token: "short".to_string(), allow_network: false },
        )
        .err()
        .unwrap();
    assert!(error.contains("token"));
}
