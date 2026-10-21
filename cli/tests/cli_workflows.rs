use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};
use std::time::{SystemTime, UNIX_EPOCH};

use serde_json::Value;

struct Sandbox(PathBuf);

impl Sandbox {
    fn new() -> Self {
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let path = std::env::temp_dir().join(format!("budget-warden-cli-{nonce}"));
        fs::create_dir_all(&path).unwrap();
        Self(path)
    }
    fn path(&self, name: &str) -> PathBuf {
        self.0.join(name)
    }
}

impl Drop for Sandbox {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn run(sandbox: &Sandbox, args: &[&str]) -> (Output, Value) {
    let output = Command::new(env!("CARGO_BIN_EXE_budget-warden"))
        .arg("--config-dir")
        .arg(sandbox.path("config"))
        .args(args)
        .output()
        .expect("run budget-warden");
    let value = serde_json::from_slice(&output.stdout).expect("one JSON response on stdout");
    (output, value)
}

fn run_with_stdin(sandbox: &Sandbox, args: &[&str], input: &str) -> (Output, Value) {
    let mut child = Command::new(env!("CARGO_BIN_EXE_budget-warden"))
        .arg("--config-dir")
        .arg(sandbox.path("config"))
        .args(args)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("run budget-warden");
    child
        .stdin
        .take()
        .expect("child stdin")
        .write_all(input.as_bytes())
        .expect("write request to stdin");
    let output = child.wait_with_output().expect("wait for budget-warden");
    let value = serde_json::from_slice(&output.stdout).expect("one JSON response on stdout");
    (output, value)
}

fn assert_success(output: &Output, value: &Value) {
    assert!(
        output.status.success(),
        "stderr: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert_eq!(value["ok"], true);
}

fn run_success(sandbox: &Sandbox, args: &[&str]) -> Value {
    let (output, value) = run(sandbox, args);
    assert_success(&output, &value);
    value
}

fn create_budget(sandbox: &Sandbox, file: &Path, title: &str, template: &str) -> Value {
    let file = file.to_str().expect("UTF-8 test path");
    run_success(
        sandbox,
        &[
            "budget",
            "create",
            "--file",
            file,
            "--title",
            title,
            "--template",
            template,
        ],
    )
}

#[test]
fn capabilities_and_argument_errors_use_the_protocol_envelope() {
    let sandbox = Sandbox::new();
    let (output, value) = run(&sandbox, &["capabilities"]);
    assert_success(&output, &value);
    assert_eq!(value["protocol_version"], 1);
    assert!(
        value["data"]["commands"]
            .as_array()
            .unwrap()
            .iter()
            .any(|name| name.as_str() == Some("apply"))
    );
    assert!(value["data"]["schemas"]["apply_request"].is_object());
    assert_eq!(value["data"]["protocol_version"], 1);
    assert_eq!(value["data"]["core_package"], "bw_core");

    let (output, value) = run(&sandbox, &["budget", "show"]);
    assert_eq!(output.status.code(), Some(2));
    assert_eq!(value["ok"], false);
    assert_eq!(value["error"]["code"], "usage_error");
}

#[test]
fn local_crud_and_dry_run_keep_budget_bytes_unchanged() {
    let sandbox = Sandbox::new();
    let file = sandbox.path("Budget with spaces-月.budget");
    let file_arg = file.to_str().unwrap();
    let (output, value) = run(
        &sandbox,
        &[
            "budget",
            "create",
            "--file",
            file_arg,
            "--title",
            "October",
            "--template",
            "empty",
        ],
    );
    assert_success(&output, &value);
    let initial_revision = value["meta"]["revision_id"].as_str().unwrap().to_string();

    let (output, value) = run(
        &sandbox,
        &[
            "category",
            "create",
            "--file",
            file_arg,
            "--title",
            "Food",
            "--type",
            "expenses",
            "--planned-minor-units",
            "64000",
            "--if-revision",
            &initial_revision,
        ],
    );
    assert_success(&output, &value);
    let category_id = value["data"]["id"].as_str().unwrap().to_string();
    let revision_id = value["meta"]["revision_id"].as_str().unwrap().to_string();

    let (output, value) = run(
        &sandbox,
        &[
            "transaction",
            "create",
            "--file",
            file_arg,
            "--category-id",
            &category_id,
            "--title",
            "Groceries",
            "--amount",
            "42.50",
            "--date",
            "2026-10-10",
            "--if-revision",
            &revision_id,
        ],
    );
    assert_success(&output, &value);
    let transaction_id = value["data"]["transaction"]["id"]
        .as_str()
        .unwrap()
        .to_string();
    let bytes_before = fs::read(&file).unwrap();
    let revision_id = value["meta"]["revision_id"].as_str().unwrap().to_string();

    let (output, value) = run(
        &sandbox,
        &[
            "transaction",
            "update",
            "--file",
            file_arg,
            "--id",
            &transaction_id,
            "--description",
            "",
            "--dry-run",
            "--if-revision",
            &revision_id,
        ],
    );
    assert_success(&output, &value);
    assert_eq!(value["data"]["dry_run"], true);
    assert_eq!(value["meta"]["write_occurred"], false);
    assert_eq!(fs::read(&file).unwrap(), bytes_before);

    let (output, value) = run(&sandbox, &["report", "summary", "--file", file_arg]);
    assert_success(&output, &value);
    assert_eq!(value["data"]["totals"]["actual_spending"], "42.50");
}

#[test]
fn failed_batch_does_not_commit_earlier_operations() {
    let sandbox = Sandbox::new();
    let file = sandbox.path("batch.budget");
    let file_arg = file.to_str().unwrap();
    let (output, value) = run(
        &sandbox,
        &[
            "budget",
            "create",
            "--file",
            file_arg,
            "--title",
            "Batch",
            "--template",
            "empty",
        ],
    );
    assert_success(&output, &value);
    let original = fs::read(&file).unwrap();
    let request = sandbox.path("changes.json");
    fs::write(&request, format!(
        "{{\"version\":1,\"file\":{},\"operations\":[{{\"op\":\"create_category\",\"local_ref\":\"food\",\"title\":\"Food\",\"category_type\":\"expenses\",\"planned_amount\":\"12.34\"}},{{\"op\":\"create_transaction\",\"category_id\":\"$missing\",\"title\":\"Bad reference\",\"date\":\"2026-10-10\",\"amount\":\"1.00\"}}]}}",
        serde_json::to_string(file.to_str().unwrap()).unwrap()
    )).unwrap();
    let request_arg = request.to_str().unwrap();
    let (output, value) = run(&sandbox, &["apply", "--input", request_arg]);
    assert_eq!(output.status.code(), Some(2));
    assert_eq!(value["ok"], false);
    assert_eq!(value["error"]["details"]["operation_index"], 1);
    assert_eq!(value["error"]["commit_outcome"], "not_written");
    assert_eq!(fs::read(Path::new(file_arg)).unwrap(), original);
}

#[test]
fn budget_lifecycle_covers_templates_reuse_copy_move_list_and_delete() {
    let sandbox = Sandbox::new();
    let source = sandbox.path("September.budget");
    let copied = sandbox.path("September replica.budget");
    let reused = sandbox.path("October.budget");
    let moved = sandbox.path("moved-September.budget");
    let source_arg = source.to_str().unwrap();
    let copied_arg = copied.to_str().unwrap();
    let reused_arg = reused.to_str().unwrap();
    let moved_arg = moved.to_str().unwrap();

    let templates = run_success(&sandbox, &["template", "list"]);
    assert_eq!(templates["data"].as_array().unwrap().len(), 9);
    let template = run_success(&sandbox, &["template", "show", "basic-monthly"]);
    assert_eq!(template["data"]["categories"].as_array().unwrap().len(), 13);

    let created = create_budget(&sandbox, &source, "September", "basic-monthly");
    let source_budget = &created["data"]["budget"];
    let budget_id = source_budget["id"].as_str().unwrap().to_string();
    let food_id = source_budget["categories"]
        .as_array()
        .unwrap()
        .iter()
        .find(|category| category["title"] == "Food")
        .unwrap()["id"]
        .as_str()
        .unwrap()
        .to_string();

    let transaction = run_success(
        &sandbox,
        &[
            "transaction",
            "create",
            "--file",
            source_arg,
            "--category-id",
            &food_id,
            "--title",
            "Market",
            "--amount",
            "18.25",
            "--date",
            "2026-09-04",
        ],
    );
    let source_revision = transaction["meta"]["revision_id"]
        .as_str()
        .unwrap()
        .to_string();

    let shown = run_success(&sandbox, &["budget", "show", "--file", source_arg]);
    assert_eq!(shown["data"]["id"], budget_id);
    assert_eq!(shown["data"]["title"], "September");
    assert_eq!(shown["meta"]["write_occurred"], false);
    assert_eq!(
        run_success(&sandbox, &["budget", "validate", "--file", source_arg])["data"]["valid"],
        true
    );

    let copied_result = run_success(
        &sandbox,
        &["budget", "copy", "--file", source_arg, "--to", copied_arg],
    );
    assert_eq!(copied_result["data"]["budget_id"], budget_id);
    assert_eq!(fs::read(&source).unwrap(), fs::read(&copied).unwrap());

    let reused_result = run_success(
        &sandbox,
        &[
            "budget", "create", "--file", reused_arg, "--title", "October", "--from", source_arg,
        ],
    );
    let reused_budget = &reused_result["data"]["budget"];
    assert_ne!(reused_budget["id"], budget_id);
    let reused_food = reused_budget["categories"]
        .as_array()
        .unwrap()
        .iter()
        .find(|category| category["title"] == "Food")
        .unwrap();
    assert_ne!(reused_food["id"], food_id);
    assert_eq!(reused_food["planned_amount"], "640.00");
    assert_eq!(reused_food["transaction_count"], 0);

    let listed = run_success(
        &sandbox,
        &["budget", "list", "--directory", sandbox.0.to_str().unwrap()],
    );
    assert_eq!(listed["data"]["budgets"].as_array().unwrap().len(), 3);

    let move_result = run_success(
        &sandbox,
        &[
            "budget",
            "move",
            "--file",
            source_arg,
            "--to",
            moved_arg,
            "--if-revision",
            &source_revision,
        ],
    );
    assert_eq!(move_result["data"]["moved"], true);
    assert!(!source.exists());
    assert!(moved.exists());
    assert_eq!(
        run_success(&sandbox, &["budget", "show", "--file", moved_arg])["data"]["id"],
        budget_id
    );

    let wrong_confirmation = uuid::Uuid::new_v4().to_string();
    let (output, value) = run(
        &sandbox,
        &[
            "budget",
            "delete",
            "--file",
            copied_arg,
            "--confirm-budget-id",
            &wrong_confirmation,
        ],
    );
    assert_eq!(output.status.code(), Some(2));
    assert_eq!(value["error"]["code"], "budget_id_mismatch");
    assert!(copied.exists());

    let deleted = run_success(
        &sandbox,
        &[
            "budget",
            "delete",
            "--file",
            copied_arg,
            "--confirm-budget-id",
            &budget_id,
        ],
    );
    assert_eq!(deleted["data"]["deleted"], true);
    assert!(!copied.exists());
}

#[test]
fn copy_only_replaces_an_existing_budget_with_its_matching_id() {
    let sandbox = Sandbox::new();
    let source = sandbox.path("source.budget");
    let destination = sandbox.path("destination.budget");
    let source_arg = source.to_str().unwrap();
    let destination_arg = destination.to_str().unwrap();
    let source_value = create_budget(&sandbox, &source, "Source", "empty");
    let destination_value = create_budget(&sandbox, &destination, "Destination", "empty");
    let destination_id = destination_value["data"]["budget"]["id"]
        .as_str()
        .unwrap()
        .to_string();
    let before = fs::read(&destination).unwrap();

    let (output, value) = run(
        &sandbox,
        &[
            "budget",
            "copy",
            "--file",
            source_arg,
            "--to",
            destination_arg,
        ],
    );
    assert_eq!(output.status.code(), Some(6));
    assert_eq!(value["error"]["code"], "destination_exists");
    assert_eq!(value["error"]["commit_outcome"], "not_written");
    assert_eq!(fs::read(&destination).unwrap(), before);

    let copied = run_success(
        &sandbox,
        &[
            "budget",
            "copy",
            "--file",
            source_arg,
            "--to",
            destination_arg,
            "--overwrite-budget-id",
            &destination_id,
        ],
    );
    assert_eq!(
        copied["data"]["budget_id"],
        source_value["data"]["budget"]["id"]
    );
    assert_eq!(fs::read(&destination).unwrap(), fs::read(&source).unwrap());
}

#[test]
fn categories_and_transactions_cover_crud_ordering_filters_and_reports() {
    let sandbox = Sandbox::new();
    let file = sandbox.path("workflow.budget");
    let file_arg = file.to_str().unwrap();
    create_budget(&sandbox, &file, "Workflow", "empty");

    let food = run_success(
        &sandbox,
        &[
            "category",
            "create",
            "--file",
            file_arg,
            "--title",
            "Food",
            "--type",
            "expenses",
            "--planned",
            "100.00",
            "--accumulated",
            "10.00",
        ],
    );
    let food_id = food["data"]["id"].as_str().unwrap().to_string();
    let travel = run_success(
        &sandbox,
        &[
            "category",
            "create",
            "--file",
            file_arg,
            "--title",
            "Travel",
            "--type",
            "expenses",
            "--planned",
            "200.00",
        ],
    );
    let travel_id = travel["data"]["id"].as_str().unwrap().to_string();
    let income = run_success(
        &sandbox,
        &[
            "category",
            "create",
            "--file",
            file_arg,
            "--title",
            "Salary",
            "--type",
            "income",
            "--planned-minor-units",
            "100000",
        ],
    );
    let income_id = income["data"]["id"].as_str().unwrap().to_string();
    let listed_income = run_success(
        &sandbox,
        &["category", "list", "--file", file_arg, "--type", "income"],
    );
    assert_eq!(listed_income["data"]["total"], 1);
    assert_eq!(listed_income["data"]["items"][0]["id"], income_id);

    let by_title = run_success(
        &sandbox,
        &[
            "category", "list", "--file", file_arg, "--type", "expenses", "--sort", "title",
            "--offset", "0", "--limit", "1",
        ],
    );
    assert_eq!(by_title["data"]["total"], 2);
    assert_eq!(by_title["data"]["items"][0]["title"], "Food");
    let found_category = run_success(
        &sandbox,
        &[
            "category", "list", "--file", file_arg, "--search", "trav", "--sort", "title",
        ],
    );
    assert_eq!(found_category["data"]["items"][0]["id"], travel_id);

    run_success(
        &sandbox,
        &[
            "category",
            "move",
            "--file",
            file_arg,
            "--id",
            &travel_id,
            "--ordinal",
            "0",
        ],
    );
    let by_ordinal = run_success(
        &sandbox,
        &[
            "category", "list", "--file", file_arg, "--type", "expenses", "--sort", "ordinal",
        ],
    );
    assert_eq!(by_ordinal["data"]["items"][0]["id"], travel_id);

    let updated_category = run_success(
        &sandbox,
        &[
            "category",
            "update",
            "--file",
            file_arg,
            "--id",
            &food_id,
            "--title",
            "Groceries",
            "--planned",
            "125.00",
            "--accumulated",
            "12.50",
        ],
    );
    assert_eq!(
        updated_category["data"]["category"]["planned_amount"],
        "125.00"
    );
    assert_eq!(
        updated_category["data"]["category"]["accumulated_amount"],
        "12.50"
    );
    let shown_category = run_success(
        &sandbox,
        &["category", "show", "--file", file_arg, "--id", &food_id],
    );
    assert_eq!(shown_category["data"]["title"], "Groceries");

    run_success(
        &sandbox,
        &[
            "category", "update", "--file", file_arg, "--id", &income_id, "--type", "savings",
        ],
    );
    assert_eq!(
        run_success(
            &sandbox,
            &["category", "list", "--file", file_arg, "--type", "income"],
        )["data"]["total"],
        0
    );
    let savings = run_success(
        &sandbox,
        &["category", "list", "--file", file_arg, "--type", "savings"],
    );
    assert_eq!(savings["data"]["items"][0]["id"], income_id);

    let grocery = run_success(
        &sandbox,
        &[
            "transaction",
            "create",
            "--file",
            file_arg,
            "--category-id",
            &food_id,
            "--title",
            "Grocery run",
            "--description",
            "Weekly market",
            "--amount",
            "42.50",
            "--date",
            "2026-01-05",
        ],
    );
    let grocery_id = grocery["data"]["transaction"]["id"]
        .as_str()
        .unwrap()
        .to_string();
    let hardware = run_success(
        &sandbox,
        &[
            "transaction",
            "create",
            "--file",
            file_arg,
            "--category-id",
            &food_id,
            "--title",
            "Hardware",
            "--description",
            "Tools",
            "--amount-minor-units",
            "1999",
            "--date",
            "2026-01-10",
        ],
    );
    let hardware_id = hardware["data"]["transaction"]["id"]
        .as_str()
        .unwrap()
        .to_string();
    let flight = run_success(
        &sandbox,
        &[
            "transaction",
            "create",
            "--file",
            file_arg,
            "--category-id",
            &travel_id,
            "--title",
            "Flight",
            "--amount",
            "150.00",
            "--date",
            "2026-02-01",
        ],
    );
    let flight_id = flight["data"]["transaction"]["id"]
        .as_str()
        .unwrap()
        .to_string();

    let updated_transaction = run_success(
        &sandbox,
        &[
            "transaction",
            "update",
            "--file",
            file_arg,
            "--id",
            &grocery_id,
            "--title",
            "Market",
            "--description",
            "",
            "--amount",
            "43.00",
            "--date",
            "2026-02-02",
        ],
    );
    assert_eq!(
        updated_transaction["data"]["transaction"]["description"],
        ""
    );
    assert_eq!(
        updated_transaction["data"]["transaction"]["amount"],
        "43.00"
    );
    let shown_transaction = run_success(
        &sandbox,
        &[
            "transaction",
            "show",
            "--file",
            file_arg,
            "--id",
            &grocery_id,
        ],
    );
    assert_eq!(shown_transaction["data"]["category_title"], "Groceries");
    assert_eq!(shown_transaction["data"]["date"], "2026-02-02");

    let filtered_by_category = run_success(
        &sandbox,
        &[
            "transaction",
            "list",
            "--file",
            file_arg,
            "--search",
            "travel",
            "--after",
            "2026-02-01",
            "--before",
            "2026-02-01",
            "--min-amount",
            "100.00",
            "--max-amount",
            "200.00",
        ],
    );
    assert_eq!(filtered_by_category["data"]["total"], 1);
    assert_eq!(filtered_by_category["data"]["items"][0]["id"], flight_id);
    let page = run_success(
        &sandbox,
        &[
            "transaction",
            "list",
            "--file",
            file_arg,
            "--sort",
            "title",
            "--offset",
            "1",
            "--limit",
            "1",
        ],
    );
    assert_eq!(page["data"]["total"], 3);
    assert_eq!(page["data"]["items"][0]["title"], "Hardware");

    run_success(
        &sandbox,
        &[
            "transaction",
            "move",
            "--file",
            file_arg,
            "--id",
            &hardware_id,
            "--category-id",
            &travel_id,
        ],
    );
    let moved_transaction = run_success(
        &sandbox,
        &[
            "transaction",
            "show",
            "--file",
            file_arg,
            "--id",
            &hardware_id,
        ],
    );
    assert_eq!(moved_transaction["data"]["category_title"], "Travel");

    run_success(
        &sandbox,
        &[
            "transaction",
            "delete",
            "--file",
            file_arg,
            "--id",
            &flight_id,
        ],
    );
    let summary = run_success(&sandbox, &["report", "summary", "--file", file_arg]);
    assert_eq!(summary["data"]["totals"]["actual_spending"], "62.99");
    assert_eq!(summary["data"]["totals"]["planned_spending"], "325.00");
    let actual_categories = run_success(
        &sandbox,
        &[
            "report",
            "categories",
            "--file",
            file_arg,
            "--mode",
            "actual",
        ],
    );
    assert!(
        actual_categories["data"]["segments"]
            .as_array()
            .unwrap()
            .iter()
            .any(|segment| segment["category_id"] == food_id && segment["amount"] == "43.00")
    );
    assert!(
        !run_success(
            &sandbox,
            &[
                "report",
                "allocation",
                "--file",
                file_arg,
                "--mode",
                "planned"
            ],
        )["data"]["segments"]
            .as_array()
            .unwrap()
            .is_empty()
    );
    assert!(
        !run_success(&sandbox, &["report", "comparison", "--file", file_arg],)["data"]["segments"]
            .as_array()
            .unwrap()
            .is_empty()
    );

    run_success(
        &sandbox,
        &["category", "delete", "--file", file_arg, "--id", &travel_id],
    );
    let remaining_transactions =
        run_success(&sandbox, &["transaction", "list", "--file", file_arg]);
    assert_eq!(remaining_transactions["data"]["total"], 1);
    assert_eq!(remaining_transactions["data"]["items"][0]["id"], grocery_id);
    let remaining_expenses = run_success(
        &sandbox,
        &["category", "list", "--file", file_arg, "--type", "expenses"],
    );
    assert_eq!(remaining_expenses["data"]["total"], 1);
    assert_eq!(remaining_expenses["data"]["items"][0]["id"], food_id);
}

#[test]
fn stale_revision_rejects_mutation_without_changing_file() {
    let sandbox = Sandbox::new();
    let file = sandbox.path("revision.budget");
    let file_arg = file.to_str().unwrap();
    let created = create_budget(&sandbox, &file, "Before", "empty");
    let stale_revision = created["meta"]["revision_id"].as_str().unwrap().to_string();

    let renamed = run_success(
        &sandbox,
        &[
            "budget",
            "rename",
            "--file",
            file_arg,
            "--title",
            "After",
            "--if-revision",
            &stale_revision,
        ],
    );
    let current_revision = renamed["meta"]["revision_id"].as_str().unwrap().to_string();
    assert_ne!(current_revision, stale_revision);
    let before_conflict = fs::read(&file).unwrap();

    let (output, value) = run(
        &sandbox,
        &[
            "budget",
            "rename",
            "--file",
            file_arg,
            "--title",
            "Must not win",
            "--if-revision",
            &stale_revision,
        ],
    );
    assert_eq!(output.status.code(), Some(5));
    assert_eq!(value["error"]["code"], "revision_conflict");
    assert_eq!(value["error"]["retryable"], true);
    assert_eq!(value["error"]["commit_outcome"], "not_written");
    assert_eq!(fs::read(&file).unwrap(), before_conflict);
    assert_eq!(
        run_success(&sandbox, &["budget", "show", "--file", file_arg])["data"]["title"],
        "After"
    );
}

#[test]
fn apply_accepts_stdin_local_references_and_dry_run() {
    let sandbox = Sandbox::new();
    let file = sandbox.path("stdin batch.budget");
    let file_arg = file.to_str().unwrap();
    let created = create_budget(&sandbox, &file, "Batch", "empty");
    let revision = created["meta"]["revision_id"].as_str().unwrap();
    let original_bytes = fs::read(&file).unwrap();
    let request = serde_json::json!({
        "version": 1,
        "file": file_arg,
        "expected_revision_id": revision,
        "operations": [
            {
                "op": "create_category",
                "local_ref": "food",
                "title": "Food",
                "category_type": "expenses",
                "planned_amount": "100.00",
                "accumulated_amount": {"minor_units": "500"}
            },
            {
                "op": "create_transaction",
                "local_ref": "lunch",
                "category_id": "$food",
                "title": "Lunch",
                "date": "2026-10-10",
                "amount": {"minor_units": "4250"}
            }
        ]
    })
    .to_string();

    let (output, preview) =
        run_with_stdin(&sandbox, &["apply", "--input", "-", "--dry-run"], &request);
    assert_success(&output, &preview);
    assert_eq!(preview["data"]["operation_count"], 2);
    assert_eq!(preview["data"]["dry_run"], true);
    assert!(preview["data"]["created_ids"]["food"].is_string());
    assert!(preview["data"]["created_ids"]["lunch"].is_string());
    assert_eq!(preview["meta"]["write_occurred"], false);
    assert_eq!(fs::read(&file).unwrap(), original_bytes);

    let (output, applied) = run_with_stdin(&sandbox, &["apply", "--input", "-"], &request);
    assert_success(&output, &applied);
    assert_eq!(applied["data"]["dry_run"], false);
    assert_eq!(applied["meta"]["write_occurred"], true);
    let show = run_success(&sandbox, &["budget", "show", "--file", file_arg]);
    assert_eq!(show["data"]["categories"].as_array().unwrap().len(), 1);
    let transactions = run_success(&sandbox, &["transaction", "list", "--file", file_arg]);
    assert_eq!(transactions["data"]["items"][0]["title"], "Lunch");
    assert_eq!(transactions["data"]["items"][0]["amount"], "42.50");
}

#[test]
fn legacy_file_reads_do_not_write_until_explicit_migration() {
    let sandbox = Sandbox::new();
    let file = sandbox.path("legacy.budget");
    fs::write(
        &file,
        include_bytes!("../../core/tests/fixtures/legacy_budget.json"),
    )
    .unwrap();
    let file_arg = file.to_str().unwrap();
    let legacy_bytes = fs::read(&file).unwrap();

    let shown = run_success(&sandbox, &["budget", "show", "--file", file_arg]);
    assert_eq!(shown["meta"]["migration_status"], "required");
    assert_eq!(shown["data"]["title"], "Old budget format");
    assert_eq!(fs::read(&file).unwrap(), legacy_bytes);
    let revision = shown["meta"]["revision_id"].as_str().unwrap();
    let reread = run_success(&sandbox, &["budget", "show", "--file", file_arg]);
    assert_eq!(reread["meta"]["revision_id"], revision);

    let migrated = run_success(
        &sandbox,
        &[
            "budget",
            "migrate",
            "--file",
            file_arg,
            "--in-place",
            "--if-revision",
            revision,
        ],
    );
    assert_eq!(migrated["data"]["migrated"], true);
    assert_ne!(migrated["meta"]["revision_id"], revision);
    assert_ne!(fs::read(&file).unwrap(), legacy_bytes);
    let current = run_success(&sandbox, &["budget", "show", "--file", file_arg]);
    assert_eq!(current["meta"]["migration_status"], "current");
    assert_eq!(current["data"]["schema_version"], 2);
    assert_eq!(
        run_success(&sandbox, &["budget", "validate", "--file", file_arg])["data"]["valid"],
        true
    );
}

#[test]
fn merge_combines_independent_changes_from_budget_replicas() {
    let sandbox = Sandbox::new();
    let base = sandbox.path("base.budget");
    let replica = sandbox.path("replica.budget");
    let base_arg = base.to_str().unwrap();
    let replica_arg = replica.to_str().unwrap();
    create_budget(&sandbox, &base, "Shared", "empty");
    let category = run_success(
        &sandbox,
        &[
            "category",
            "create",
            "--file",
            base_arg,
            "--title",
            "Original",
            "--type",
            "expenses",
            "--planned",
            "100.00",
        ],
    );
    let category_id = category["data"]["id"].as_str().unwrap().to_string();
    run_success(
        &sandbox,
        &["budget", "copy", "--file", base_arg, "--to", replica_arg],
    );

    let base_update = run_success(
        &sandbox,
        &[
            "category",
            "update",
            "--file",
            base_arg,
            "--id",
            &category_id,
            "--title",
            "Essentials",
        ],
    );
    let base_revision = base_update["meta"]["revision_id"]
        .as_str()
        .unwrap()
        .to_string();
    run_success(
        &sandbox,
        &[
            "category",
            "update",
            "--file",
            replica_arg,
            "--id",
            &category_id,
            "--planned",
            "200.00",
        ],
    );

    let merged = run_success(
        &sandbox,
        &[
            "budget",
            "merge",
            "--file",
            base_arg,
            "--other",
            replica_arg,
            "--if-revision",
            &base_revision,
        ],
    );
    assert_eq!(merged["data"]["merged"], true);
    let category = run_success(
        &sandbox,
        &["category", "show", "--file", base_arg, "--id", &category_id],
    );
    assert_eq!(category["data"]["title"], "Essentials");
    assert_eq!(category["data"]["planned_amount"], "200.00");
}

#[test]
fn config_and_recent_commands_persist_cli_preferences() {
    let sandbox = Sandbox::new();
    let file = sandbox.path("recent.budget");
    let file_arg = file.to_str().unwrap();
    create_budget(&sandbox, &file, "Recent", "empty");

    let currency = run_success(&sandbox, &["config", "set", "--currency", "usd"]);
    assert_eq!(currency["data"]["currency"], "USD");
    let paths = run_success(&sandbox, &["config", "paths"]);
    assert_eq!(
        paths["data"]["config_directory"],
        sandbox.path("config").to_str().unwrap()
    );
    let (output, added) = run(&sandbox, &["recent", "add", file_arg]);
    assert_success(&output, &added);
    assert_eq!(added["data"]["count"], 1);
    let duplicate = run_success(&sandbox, &["recent", "add", file_arg]);
    assert_eq!(duplicate["data"]["count"], 1);
    let config = run_success(&sandbox, &["config", "show"]);
    assert_eq!(config["data"]["currency"], "USD");
    assert!(config["data"]["device_id"].is_string());
    assert_eq!(config["data"]["recent_file_count"], 1);
    let recent = run_success(&sandbox, &["recent", "list"]);
    assert_eq!(recent["data"]["files"][0], file_arg);
    let removed = run_success(&sandbox, &["recent", "remove", file_arg]);
    assert_eq!(removed["data"]["removed"], true);
    assert!(
        run_success(&sandbox, &["recent", "list"])["data"]["files"]
            .as_array()
            .unwrap()
            .is_empty()
    );
}

#[test]
fn structured_input_and_transaction_values_reject_unknown_or_invalid_fields() {
    let sandbox = Sandbox::new();
    let file = sandbox.path("strict-input.budget");
    let file_arg = file.to_str().unwrap();
    create_budget(&sandbox, &file, "Strict input", "empty");
    let before = fs::read(&file).unwrap();
    let bad_request = serde_json::json!({
        "version": 1,
        "file": file_arg,
        "unexpected": true,
        "operations": [{"op": "rename_budget", "title": "Changed"}]
    })
    .to_string();
    let request_file = sandbox.path("unknown-field.json");
    fs::write(&request_file, bad_request).unwrap();
    let request_arg = request_file.to_str().unwrap();
    let (output, value) = run(&sandbox, &["apply", "--input", request_arg]);
    assert_eq!(output.status.code(), Some(2));
    assert_eq!(value["error"]["code"], "usage_error");
    assert_eq!(fs::read(&file).unwrap(), before);

    let (output, value) = run(
        &sandbox,
        &[
            "transaction",
            "create",
            "--file",
            file_arg,
            "--category-id",
            "00000000-0000-0000-0000-000000000001",
            "--title",
            "Invalid date",
            "--amount",
            "1.00",
            "--date",
            "2026-02-30",
        ],
    );
    assert_eq!(output.status.code(), Some(2));
    assert_eq!(value["error"]["code"], "usage_error");
    assert_eq!(fs::read(&file).unwrap(), before);

    let (output, value) = run(
        &sandbox,
        &[
            "transaction",
            "create",
            "--file",
            file_arg,
            "--category-id",
            "00000000-0000-0000-0000-000000000001",
            "--title",
            "Invalid amount",
            "--amount",
            "1.001",
            "--date",
            "2026-02-28",
        ],
    );
    assert_eq!(output.status.code(), Some(2));
    assert_eq!(value["error"]["code"], "usage_error");
    assert_eq!(fs::read(&file).unwrap(), before);
}

#[cfg(unix)]
#[test]
fn writes_reject_symbolic_link_targets() {
    use std::os::unix::fs::symlink;

    let sandbox = Sandbox::new();
    let target = sandbox.path("target.budget");
    let alias = sandbox.path("alias.budget");
    let target_arg = target.to_str().unwrap();
    let alias_arg = alias.to_str().unwrap();
    create_budget(&sandbox, &target, "Target", "empty");
    symlink(&target, &alias).unwrap();
    let before = fs::read(&target).unwrap();

    let (output, value) = run(
        &sandbox,
        &[
            "budget",
            "rename",
            "--file",
            alias_arg,
            "--title",
            "Through symlink",
        ],
    );
    assert_eq!(output.status.code(), Some(6));
    assert_eq!(value["error"]["code"], "symlink_not_supported");
    assert_eq!(value["error"]["commit_outcome"], "not_written");
    assert_eq!(fs::read(&target).unwrap(), before);
    assert_eq!(
        run_success(&sandbox, &["budget", "show", "--file", target_arg])["data"]["title"],
        "Target"
    );
}

#[test]
fn mutation_waits_for_the_sidecar_lock_then_returns_a_bounded_timeout() {
    use fs2::FileExt;

    let sandbox = Sandbox::new();
    let file = sandbox.path("locked.budget");
    let file_arg = file.to_str().unwrap();
    create_budget(&sandbox, &file, "Locked", "empty");
    let mut sidecar_name = file.file_name().unwrap().to_os_string();
    sidecar_name.push(".budget-warden.lock");
    let sidecar = file.with_file_name(sidecar_name);
    let lock_file = OpenOptions::new()
        .read(true)
        .write(true)
        .open(sidecar)
        .unwrap();
    lock_file.lock_exclusive().unwrap();

    let (output, value) = run(
        &sandbox,
        &[
            "budget",
            "rename",
            "--file",
            file_arg,
            "--title",
            "Blocked writer",
        ],
    );
    FileExt::unlock(&lock_file).unwrap();

    assert_eq!(output.status.code(), Some(5));
    assert_eq!(value["error"]["code"], "lock_timeout");
    assert_eq!(value["error"]["retryable"], true);
    assert_eq!(value["error"]["commit_outcome"], "not_written");
    assert_eq!(
        run_success(&sandbox, &["budget", "show", "--file", file_arg])["data"]["title"],
        "Locked"
    );
}

#[test]
fn list_accepts_current_directory_path() {
    let sandbox = Sandbox::new();
    create_budget(&sandbox, &sandbox.path("listed.budget"), "Listed", "empty");
    let output = Command::new(env!("CARGO_BIN_EXE_budget-warden"))
        .current_dir(&sandbox.0)
        .args(["budget", "list", "--directory", "."])
        .output()
        .unwrap();
    let value: Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_success(&output, &value);
    assert_eq!(value["data"]["budgets"].as_array().unwrap().len(), 1);
    assert_eq!(value["data"]["budgets"][0]["title"], "Listed");
}

#[test]
fn legacy_revision_can_guard_a_mutation_and_move() {
    let sandbox = Sandbox::new();
    let file = sandbox.path("legacy.budget");
    fs::write(
        &file,
        include_bytes!("../../core/tests/fixtures/legacy_budget.json"),
    )
    .unwrap();
    let file_arg = file.to_str().unwrap();
    let shown = run_success(&sandbox, &["budget", "show", "--file", file_arg]);
    let revision = shown["meta"]["revision_id"].as_str().unwrap();
    let moved = sandbox.path("moved.budget");
    run_success(
        &sandbox,
        &[
            "budget",
            "move",
            "--file",
            file_arg,
            "--to",
            moved.to_str().unwrap(),
            "--if-revision",
            revision,
        ],
    );
    let renamed = run_success(
        &sandbox,
        &[
            "budget",
            "rename",
            "--file",
            moved.to_str().unwrap(),
            "--title",
            "Migrated by mutation",
            "--if-revision",
            revision,
        ],
    );
    assert_eq!(renamed["meta"]["migration_status"], "current");
    assert_ne!(renamed["meta"]["revision_id"], revision);
}

#[cfg(unix)]
#[test]
fn budget_creation_is_private_and_replacement_preserves_permissions() {
    use std::os::unix::fs::PermissionsExt;
    let sandbox = Sandbox::new();
    let file = sandbox.path("private.budget");
    create_budget(&sandbox, &file, "Private", "empty");
    assert_eq!(fs::metadata(&file).unwrap().permissions().mode() & 0o077, 0);
    fs::set_permissions(&file, fs::Permissions::from_mode(0o640)).unwrap();
    run_success(
        &sandbox,
        &[
            "budget",
            "rename",
            "--file",
            file.to_str().unwrap(),
            "--title",
            "Renamed",
        ],
    );
    assert_eq!(
        fs::metadata(&file).unwrap().permissions().mode() & 0o777,
        0o640
    );
}

#[cfg(target_os = "linux")]
#[test]
fn failed_stdout_write_returns_io_exit_code() {
    let output = Command::new(env!("CARGO_BIN_EXE_budget-warden"))
        .arg("capabilities")
        .stdout(OpenOptions::new().write(true).open("/dev/full").unwrap())
        .output()
        .unwrap();
    assert_eq!(output.status.code(), Some(6));
    assert!(String::from_utf8_lossy(&output.stderr).contains("Could not write command response"));
}

fn run_cloud(sandbox: &Sandbox, client_id: Option<&str>, args: &[&str]) -> (Output, Value) {
    let mut command = Command::new(env!("CARGO_BIN_EXE_budget-warden"));
    command
        .arg("--config-dir")
        .arg(sandbox.path("config"))
        .args(args)
        .env_remove("BUDGET_WARDEN_GOOGLE_CLIENT_SECRET");
    match client_id {
        Some(id) => command.env("BUDGET_WARDEN_GOOGLE_CLIENT_ID", id),
        None => command.env("BUDGET_WARDEN_GOOGLE_CLIENT_ID", ""),
    };
    let output = command.output().expect("run budget-warden");
    let value = serde_json::from_slice(&output.stdout).expect("one JSON response on stdout");
    (output, value)
}

#[test]
fn cloud_commands_report_configuration_and_sign_in_state_without_network() {
    let sandbox = Sandbox::new();
    let capabilities = run_success(&sandbox, &["capabilities"]);
    let commands = capabilities["data"]["commands"].as_array().unwrap();
    for command in [
        "cloud status",
        "cloud sign-in",
        "cloud sync",
        "cloud share",
        "cloud unshare",
    ] {
        assert!(commands.iter().any(|value| value == command), "{command}");
    }

    let (output, status) = run_cloud(&sandbox, None, &["cloud", "status"]);
    assert_success(&output, &status);
    assert_eq!(status["data"]["configured"], false);
    assert_eq!(status["data"]["signed_in"], false);
    assert!(
        status["data"]["working_directory"]
            .as_str()
            .unwrap()
            .starts_with(sandbox.path("config").to_str().unwrap())
    );

    let (output, unconfigured) = run_cloud(&sandbox, None, &["cloud", "list"]);
    assert_eq!(output.status.code(), Some(2));
    assert_eq!(unconfigured["error"]["code"], "cloud_not_configured");

    let client = Some("test.apps.googleusercontent.com");
    let (output, signed_out) = run_cloud(&sandbox, client, &["cloud", "list"]);
    assert_eq!(output.status.code(), Some(7));
    assert_eq!(signed_out["error"]["code"], "sign_in_required");
    assert!(
        !signed_out["error"]["message"]
            .as_str()
            .unwrap()
            .starts_with("SIGN_IN_REQUIRED")
    );

    let (output, add_shared) =
        run_cloud(&sandbox, client, &["cloud", "add-shared", "--no-browser"]);
    assert_eq!(output.status.code(), Some(7));
    assert_eq!(add_shared["error"]["code"], "sign_in_required");

    let (output, offline) = run_cloud(&sandbox, client, &["cloud", "list", "--offline"]);
    assert_success(&output, &offline);
    assert_eq!(offline["data"]["budgets"], serde_json::json!([]));

    let local = sandbox.path("local.budget");
    create_budget(&sandbox, &local, "Local", "basic-monthly");
    let (output, not_cloud) = run_cloud(
        &sandbox,
        client,
        &["cloud", "sync", "--file", local.to_str().unwrap()],
    );
    assert_eq!(output.status.code(), Some(2));
    assert_eq!(not_cloud["error"]["code"], "usage_error");

    let (output, bad_email) = run_cloud(
        &sandbox,
        client,
        &["cloud", "share", "--id", "file1", "--email", "nobody"],
    );
    assert_eq!(output.status.code(), Some(4));
    assert_eq!(bad_email["error"]["code"], "cloud_error");

    let (output, signed_out) = run_cloud(&sandbox, client, &["cloud", "sign-out"]);
    assert_success(&output, &signed_out);
    assert_eq!(signed_out["data"]["signed_out"], false);
}
