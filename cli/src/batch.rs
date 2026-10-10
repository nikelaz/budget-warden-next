use std::collections::HashMap;
use std::fs;
use std::io::{self, Read};
use std::path::PathBuf;

use serde_json::{Map, Value, json};
use uuid::Uuid;

use crate::args::ApplyArgs;
use crate::commands::{Context, meta_for_mutation, mutate};
use crate::error::{ApiError, core_error, io_error, missing_entity, usage_error};
use crate::protocol::{ApplyRequest, ApplyResult, Operation};
use crate::util::{category_type_name, date, money_input, parse_category_type, parse_uuid_ref};
use crate::{Outcome, success};
use bw_core::models::{BWBudget, BWCategory, BWMoneyAmount};

const MAX_REQUEST_BYTES: u64 = 4 * 1024 * 1024;
const MAX_OPERATIONS: usize = 1000;

pub fn run_apply(mut context: Context, args: ApplyArgs) -> Result<Outcome, ApiError> {
    let input = if args.input == "-" {
        read_request(io::stdin(), "stdin")?
    } else {
        let file = fs::File::open(&args.input).map_err(|error| io_error(error, &args.input))?;
        read_request(file, &args.input)?
    };
    let request: ApplyRequest = serde_json::from_str(&input)
        .map_err(|error| usage_error(format!("Invalid apply request JSON: {error}")))?;
    if request.version != 1 {
        return Err(usage_error(format!(
            "Unsupported apply request version: {}",
            request.version
        )));
    }
    if request.file.trim().is_empty() {
        return Err(usage_error("Apply request file path cannot be empty"));
    }
    if request.operations.is_empty() {
        return Err(usage_error(
            "Apply request must contain at least one operation",
        ));
    }
    if request.operations.len() > MAX_OPERATIONS {
        return Err(usage_error(format!(
            "Apply request exceeds the {MAX_OPERATIONS} operation limit"
        )));
    }
    if let (Some(cli_revision), Some(request_revision)) =
        (args.if_revision, request.expected_revision_id)
    {
        if cli_revision != request_revision {
            return Err(usage_error(
                "--if-revision conflicts with expected_revision_id in the request",
            ));
        }
    }
    let expected = args.if_revision.or(request.expected_revision_id);
    let file = PathBuf::from(request.file);
    let operation_count = request.operations.len();
    let (budget, original, wrote, batch_result) = mutate(
        &mut context,
        &file,
        expected,
        args.dry_run,
        move |mut budget| {
            let mut refs = HashMap::<String, Uuid>::new();
            let mut created = Map::new();
            let mut summaries = Vec::new();
            for (index, operation) in request.operations.into_iter().enumerate() {
                let operation_name = operation_name(&operation);
                match apply_operation(budget, operation, &mut refs, &mut created) {
                    Ok((updated, summary)) => {
                        budget = updated;
                        summaries.push(
                            json!({"index":index,"operation":operation_name,"result":summary}),
                        );
                    }
                    Err(mut error) => {
                        let cause = error.details.clone();
                        error.details = json!({"operation_index": index, "operation": operation_name, "cause": cause});
                        return Err(error);
                    }
                }
            }
            Ok((budget, (Value::Object(created), Value::Array(summaries))))
        },
    )?;
    let (created_ids, summaries) = batch_result;
    let result = ApplyResult {
        version: 1,
        dry_run: args.dry_run,
        operation_count,
        created_ids,
        proposed_change_summary: summaries,
    };
    let data = serde_json::to_value(result)
        .map_err(|error| ApiError::new("internal_error", error.to_string(), 1))?;
    let meta = meta_for_mutation(
        "apply",
        &budget,
        original.requires_migration_writeback,
        wrote,
    );
    Ok(success("apply", data, Some(meta)))
}

fn read_request(reader: impl Read, source: &str) -> Result<String, ApiError> {
    let mut bytes = Vec::new();
    reader
        .take(MAX_REQUEST_BYTES + 1)
        .read_to_end(&mut bytes)
        .map_err(|error| io_error(error, source))?;
    if bytes.len() as u64 > MAX_REQUEST_BYTES {
        return Err(usage_error("Apply request exceeds the 4 MiB size limit"));
    }
    String::from_utf8(bytes)
        .map_err(|error| usage_error(format!("Apply request must be UTF-8 JSON: {error}")))
}

fn apply_operation(
    budget: BWBudget,
    operation: Operation,
    refs: &mut HashMap<String, Uuid>,
    created: &mut Map<String, Value>,
) -> Result<(BWBudget, Value), ApiError> {
    match operation {
        Operation::RenameBudget { title } => {
            let updated = bw_core::domain::update_budget_title(budget, title.clone())
                .map_err(|message| core_error("mutation_failed", message))?;
            Ok((updated, json!({"title":title})))
        }
        Operation::CreateCategory {
            local_ref,
            title,
            category_type,
            planned_amount,
            accumulated_amount,
            ordinal,
        } => {
            let category_type = parse_category_type(&category_type)?;
            let planned = money_input(&planned_amount)?;
            let accumulated = accumulated_amount
                .as_ref()
                .map(money_input)
                .transpose()?
                .unwrap_or(BWMoneyAmount { value: 0 });
            let count = budget
                .categories
                .iter()
                .filter(|category| category.category_type == category_type)
                .count();
            let ordinal = ordinal.unwrap_or(count);
            if ordinal > count {
                return Err(usage_error(
                    "Category ordinal must be between zero and the category count",
                ));
            }
            let requested_ordinal =
                i32::try_from(ordinal).map_err(|_| usage_error("Category ordinal is too large"))?;
            let append_ordinal =
                i32::try_from(count).map_err(|_| usage_error("Category count is too large"))?;
            let category = BWCategory {
                id: Uuid::new_v4(),
                ordinal: append_ordinal,
                title,
                amount_planned: planned,
                amount_actual: BWMoneyAmount { value: 0 },
                amount_accumulated: accumulated,
                category_type,
                transactions: Vec::new(),
            };
            let id = category.id;
            let mut updated = bw_core::domain::create_category(budget, category)
                .map_err(|message| core_error("mutation_failed", message))?;
            if requested_ordinal != append_ordinal {
                let mut created = updated
                    .categories
                    .iter()
                    .find(|category| category.id == id)
                    .cloned()
                    .ok_or_else(|| missing_entity("category", id.to_string()))?;
                created.ordinal = requested_ordinal;
                updated = bw_core::domain::update_category(updated, created)
                    .map_err(|message| core_error("mutation_failed", message))?;
            }
            if let Some(local_ref) = local_ref {
                register_ref(local_ref, id, refs, created)?;
            }
            Ok((
                updated,
                json!({"id":id,"type":category_type_name(category_type)}),
            ))
        }
        Operation::UpdateCategory {
            id,
            title,
            category_type,
            planned_amount,
            accumulated_amount,
            ordinal,
        } => {
            if title.is_none()
                && category_type.is_none()
                && planned_amount.is_none()
                && accumulated_amount.is_none()
                && ordinal.is_none()
            {
                return Err(usage_error("update_category requires at least one field"));
            }
            let id = parse_uuid_ref(&id, refs)?;
            let mut category = budget
                .categories
                .iter()
                .find(|category| category.id == id)
                .cloned()
                .ok_or_else(|| missing_entity("category", id.to_string()))?;
            if let Some(title) = title {
                category.title = title;
            }
            if let Some(category_type) = category_type {
                category.category_type = parse_category_type(&category_type)?;
            }
            if let Some(amount) = planned_amount {
                category.amount_planned = money_input(&amount)?;
            }
            if let Some(amount) = accumulated_amount {
                category.amount_accumulated = money_input(&amount)?;
            }
            if let Some(ordinal) = ordinal {
                category.ordinal = i32::try_from(ordinal)
                    .map_err(|_| usage_error("Category ordinal is too large"))?;
            }
            let updated = bw_core::domain::update_category(budget, category)
                .map_err(|message| core_error("mutation_failed", message))?;
            Ok((updated, json!({"id":id,"updated":true})))
        }
        Operation::DeleteCategory { id } => {
            let id = parse_uuid_ref(&id, refs)?;
            if !budget.categories.iter().any(|category| category.id == id) {
                return Err(missing_entity("category", id.to_string()));
            }
            let updated = bw_core::domain::delete_category(budget, id)
                .map_err(|message| core_error("mutation_failed", message))?;
            Ok((updated, json!({"id":id,"deleted":true})))
        }
        Operation::MoveCategory { id, ordinal } => {
            let id = parse_uuid_ref(&id, refs)?;
            let mut category = budget
                .categories
                .iter()
                .find(|category| category.id == id)
                .cloned()
                .ok_or_else(|| missing_entity("category", id.to_string()))?;
            category.ordinal =
                i32::try_from(ordinal).map_err(|_| usage_error("Category ordinal is too large"))?;
            let updated = bw_core::domain::update_category(budget, category)
                .map_err(|message| core_error("mutation_failed", message))?;
            Ok((updated, json!({"id":id,"ordinal":ordinal})))
        }
        Operation::CreateTransaction {
            local_ref,
            category_id,
            title,
            description,
            date: date_text,
            amount,
        } => {
            let category_id = parse_uuid_ref(&category_id, refs)?;
            if !budget
                .categories
                .iter()
                .any(|category| category.id == category_id)
            {
                return Err(missing_entity("category", category_id.to_string()));
            }
            let transaction_date = date(&date_text)?;
            let amount = money_input(&amount)?;
            let transaction = bw_core::models::new_transaction(
                title,
                Some(description),
                Some(transaction_date),
                amount,
            )
            .map_err(|message| core_error("mutation_failed", message))?;
            let id = transaction.id;
            let updated = bw_core::domain::create_transaction(budget, category_id, transaction)
                .map_err(|message| core_error("mutation_failed", message))?;
            if let Some(local_ref) = local_ref {
                register_ref(local_ref, id, refs, created)?;
            }
            Ok((updated, json!({"id":id,"category_id":category_id})))
        }
        Operation::UpdateTransaction {
            id,
            title,
            description,
            date: date_text,
            amount,
        } => {
            if title.is_none() && description.is_none() && date_text.is_none() && amount.is_none() {
                return Err(usage_error(
                    "update_transaction requires at least one field",
                ));
            }
            let id = parse_uuid_ref(&id, refs)?;
            let category_id = budget
                .categories
                .iter()
                .find(|category| {
                    category
                        .transactions
                        .iter()
                        .any(|transaction| transaction.id == id)
                })
                .map(|category| category.id)
                .ok_or_else(|| missing_entity("transaction", id.to_string()))?;
            let mut transaction = budget
                .categories
                .iter()
                .find(|category| category.id == category_id)
                .and_then(|category| {
                    category
                        .transactions
                        .iter()
                        .find(|transaction| transaction.id == id)
                })
                .cloned()
                .expect("located above");
            if let Some(title) = title {
                transaction.title = title;
            }
            if let Some(description) = description {
                transaction.description = description;
            }
            if let Some(date_text) = date_text {
                transaction.date = date(&date_text)?;
            }
            if let Some(amount) = amount {
                transaction.amount = money_input(&amount)?;
            }
            let updated = bw_core::domain::update_transaction(budget, category_id, transaction)
                .map_err(|message| core_error("mutation_failed", message))?;
            Ok((updated, json!({"id":id,"updated":true})))
        }
        Operation::DeleteTransaction { id } => {
            let id = parse_uuid_ref(&id, refs)?;
            let category_id = budget
                .categories
                .iter()
                .find(|category| {
                    category
                        .transactions
                        .iter()
                        .any(|transaction| transaction.id == id)
                })
                .map(|category| category.id)
                .ok_or_else(|| missing_entity("transaction", id.to_string()))?;
            let updated = bw_core::domain::delete_transaction(budget, category_id, id)
                .map_err(|message| core_error("mutation_failed", message))?;
            Ok((updated, json!({"id":id,"deleted":true})))
        }
        Operation::MoveTransaction { id, category_id } => {
            let id = parse_uuid_ref(&id, refs)?;
            let category_id = parse_uuid_ref(&category_id, refs)?;
            if !budget
                .categories
                .iter()
                .any(|category| category.id == category_id)
            {
                return Err(missing_entity("category", category_id.to_string()));
            }
            let origin_id = budget
                .categories
                .iter()
                .find(|category| {
                    category
                        .transactions
                        .iter()
                        .any(|transaction| transaction.id == id)
                })
                .map(|category| category.id)
                .ok_or_else(|| missing_entity("transaction", id.to_string()))?;
            let updated = bw_core::domain::move_transaction(budget, origin_id, category_id, id)
                .map_err(|message| core_error("mutation_failed", message))?;
            Ok((updated, json!({"id":id,"category_id":category_id})))
        }
    }
}

fn register_ref(
    name: String,
    id: Uuid,
    refs: &mut HashMap<String, Uuid>,
    created: &mut Map<String, Value>,
) -> Result<(), ApiError> {
    if name.is_empty() || name.starts_with('$') {
        return Err(usage_error(
            "local_ref must be nonempty and must not start with '$'",
        ));
    }
    if refs.contains_key(&name) {
        return Err(ApiError::new(
            "duplicate_reference",
            format!("Local reference already exists: {name}"),
            2,
        ));
    }
    refs.insert(name.clone(), id);
    created.insert(name, json!(id));
    Ok(())
}

fn operation_name(operation: &Operation) -> &'static str {
    match operation {
        Operation::RenameBudget { .. } => "rename_budget",
        Operation::CreateCategory { .. } => "create_category",
        Operation::UpdateCategory { .. } => "update_category",
        Operation::DeleteCategory { .. } => "delete_category",
        Operation::MoveCategory { .. } => "move_category",
        Operation::CreateTransaction { .. } => "create_transaction",
        Operation::UpdateTransaction { .. } => "update_transaction",
        Operation::DeleteTransaction { .. } => "delete_transaction",
        Operation::MoveTransaction { .. } => "move_transaction",
    }
}
