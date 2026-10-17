/*
 * Budget Warden
 * Copyright (c) 2026 Lazarov & Co EOOD
 * Author: Nikola Lazarov
 *
 * Licensed under the Source-Available Educational License.
 * See the LICENSE file in the project root for full terms.
 */

//! MCP tools and the budget operations behind them.

use std::sync::{Arc, Mutex};

use chrono::NaiveDate;
use serde_json::{Value, json};
use uuid::Uuid;

use super::BWMcpHost;
use crate::codec::{decode_budget, encode_budget};
use crate::domain;
use crate::models::{BWBudget, BWCategory, BWCategoryType, BWDate, BWMoneyAmount, BWTransaction};
use crate::money::{format_money_input, parse_money_amount};
use crate::reporting::{
    BWReportingAmountMode, BWReportingComparisonRow, BWReportingComponent, build_reporting_summary,
};
use crate::templates::{budget_from_previous_budget, budget_from_template_id, template_catalog};

const DEFAULT_TEMPLATE_ID: &str = "basic-monthly";
const DEFAULT_TRANSACTION_LIMIT: usize = 200;

type ToolResult = Result<Value, String>;

/// Runs tool calls against the host's budget documents.
pub(crate) struct BudgetService {
    host: Arc<dyn BWMcpHost>,
    // Serializes read-modify-write cycles so concurrent tool calls cannot
    // overwrite one another.
    lock: Mutex<()>,
}

struct LoadedBudget {
    location: String,
    budget: BWBudget,
}

impl BudgetService {
    pub fn new(host: Arc<dyn BWMcpHost>) -> Self {
        Self {
            host,
            lock: Mutex::new(()),
        }
    }

    pub fn call(&self, name: &str, arguments: &Value) -> ToolResult {
        let _guard = self.lock.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        let arguments = Arguments(arguments);
        match name {
            "list_budgets" => self.list_budgets(),
            "list_templates" => Ok(list_templates()),
            "create_budget" => self.create_budget(arguments),
            "get_budget" => self.get_budget(arguments),
            "rename_budget" => self.rename_budget(arguments),
            "open_budget_in_app" => self.open_budget_in_app(arguments),
            "get_report" => self.get_report(arguments),
            "list_categories" => self.list_categories(arguments),
            "get_category" => self.get_category(arguments),
            "create_category" => self.create_category(arguments),
            "update_category" => self.update_category(arguments),
            "delete_category" => self.delete_category(arguments),
            "list_transactions" => self.list_transactions(arguments),
            "create_transaction" => self.create_transaction(arguments),
            "update_transaction" => self.update_transaction(arguments),
            "delete_transaction" => self.delete_transaction(arguments),
            _ => Err(format!("Unknown tool: {name}")),
        }
    }

    // Storage

    fn read(&self, location: &str) -> Result<BWBudget, String> {
        let json = self.host.read_budget_file(location.to_string())?;
        let mut budget = decode_budget(&json, location.to_string())?;
        // TEMPORARY LEGACY MIGRATION: mirror the apps' schema-v1 writeback.
        if budget.requires_migration_writeback {
            self.host
                .write_budget_file(location.to_string(), encode_budget(&budget)?)?;
            budget.requires_migration_writeback = false;
        }
        budget.update_actuals()
    }

    fn resolve(&self, arguments: Arguments) -> Result<LoadedBudget, String> {
        self.resolve_reference(arguments.required_str("budget")?)
    }

    /// Finds a budget by its host location or by its id.
    fn resolve_reference(&self, reference: &str) -> Result<LoadedBudget, String> {
        let locations = self.host.list_budgets();
        if let Some(entry) = locations.iter().find(|entry| entry.location == reference) {
            return Ok(LoadedBudget {
                location: entry.location.clone(),
                budget: self.read(&entry.location)?,
            });
        }
        if let Ok(id) = Uuid::parse_str(reference) {
            for entry in &locations {
                if let Ok(budget) = self.read(&entry.location)
                    && budget.id == id
                {
                    return Ok(LoadedBudget {
                        location: entry.location.clone(),
                        budget,
                    });
                }
            }
        }
        Err(format!(
            "Unknown budget '{reference}'. Call list_budgets for the budgets the app can reach."
        ))
    }

    /// Merges `updated` with the latest stored copy, writes it, and tells the
    /// app about the change.
    fn save(&self, location: &str, updated: BWBudget) -> Result<BWBudget, String> {
        let updated = updated.update_actuals()?;
        let on_disk = self.read(location)?;
        let mut merged = domain::merge_budget_for_save(updated, on_disk)?.update_actuals()?;
        self.host
            .write_budget_file(location.to_string(), encode_budget(&merged)?)?;
        merged.url = Some(location.to_string());
        self.host.budget_did_change(location.to_string());
        Ok(merged)
    }

    fn mutate(
        &self,
        arguments: Arguments,
        operation: impl FnOnce(BWBudget) -> Result<BWBudget, String>,
    ) -> Result<LoadedBudget, String> {
        let loaded = self.resolve(arguments)?;
        let updated = operation(loaded.budget)?;
        let budget = self.save(&loaded.location, updated)?;
        Ok(LoadedBudget {
            location: loaded.location,
            budget,
        })
    }

    fn is_open(&self, location: &str) -> bool {
        self.host
            .list_budgets()
            .iter()
            .any(|entry| entry.location == location && entry.is_open)
    }

    // Budgets

    fn list_budgets(&self) -> ToolResult {
        let budgets: Vec<Value> = self
            .host
            .list_budgets()
            .into_iter()
            .map(|entry| match self.read(&entry.location) {
                Ok(budget) => json!({
                    "budget": entry.location,
                    "id": budget.id.to_string(),
                    "title": budget.title,
                    "is_open": entry.is_open,
                    "category_count": budget.categories.len(),
                    "transaction_count": transaction_count(&budget),
                }),
                Err(error) => json!({
                    "budget": entry.location,
                    "is_open": entry.is_open,
                    "error": error,
                }),
            })
            .collect();
        Ok(json!({ "currency": self.host.currency_code(), "budgets": budgets }))
    }

    fn create_budget(&self, arguments: Arguments) -> ToolResult {
        let title = arguments.required_str("title")?.trim().to_string();
        if title.is_empty() {
            return Err("Budget title cannot be empty".to_string());
        }
        let template_id = arguments.optional_str("template_id")?;
        let budget = if let Some(copy_from) = arguments.optional_str("copy_from")? {
            if template_id.is_some() {
                return Err("Pass either template_id or copy_from, not both.".to_string());
            }
            let previous = self.resolve_reference(copy_from)?;
            budget_from_previous_budget(previous.budget, title.clone())?
        } else {
            budget_from_template_id(
                template_id.unwrap_or(DEFAULT_TEMPLATE_ID).to_string(),
                title.clone(),
            )?
        };

        let location = self
            .host
            .create_budget_file(budget_file_name(&title), encode_budget(&budget)?)?;
        if arguments.optional_bool("open_in_app")?.unwrap_or(false) {
            self.host.show_budget(location.clone())?;
        }
        let budget = self.read(&location)?;
        Ok(budget_json(&location, &budget, self.is_open(&location), false))
    }

    fn get_budget(&self, arguments: Arguments) -> ToolResult {
        let loaded = self.resolve(arguments)?;
        let include_transactions = arguments.optional_bool("include_transactions")?.unwrap_or(false);
        let mut value = budget_json(
            &loaded.location,
            &loaded.budget,
            self.is_open(&loaded.location),
            include_transactions,
        );
        value["currency"] = json!(self.host.currency_code());
        value["totals"] = report_json(&loaded.budget)?["totals"].take();
        Ok(value)
    }

    fn rename_budget(&self, arguments: Arguments) -> ToolResult {
        let title = arguments.required_str("title")?.trim().to_string();
        let loaded = self.mutate(arguments, |budget| domain::update_budget_title(budget, title))?;
        Ok(budget_json(&loaded.location, &loaded.budget, self.is_open(&loaded.location), false))
    }

    fn open_budget_in_app(&self, arguments: Arguments) -> ToolResult {
        let loaded = self.resolve(arguments)?;
        self.host.show_budget(loaded.location.clone())?;
        Ok(budget_json(&loaded.location, &loaded.budget, true, false))
    }

    fn get_report(&self, arguments: Arguments) -> ToolResult {
        let loaded = self.resolve(arguments)?;
        let mut report = report_json(&loaded.budget)?;
        report["budget"] = json!(loaded.location);
        report["currency"] = json!(self.host.currency_code());
        Ok(report)
    }

    // Categories

    fn list_categories(&self, arguments: Arguments) -> ToolResult {
        let loaded = self.resolve(arguments)?;
        let category_type = arguments.optional_category_type("type")?;
        let categories: Vec<Value> = loaded
            .budget
            .ordered_categories(category_type)
            .iter()
            .map(|category| category_json(category, false))
            .collect();
        Ok(json!({ "budget": loaded.location, "categories": categories }))
    }

    fn get_category(&self, arguments: Arguments) -> ToolResult {
        let loaded = self.resolve(arguments)?;
        let category = find_category(&loaded.budget, arguments.required_uuid("category_id")?)?;
        Ok(category_json(category, true))
    }

    fn create_category(&self, arguments: Arguments) -> ToolResult {
        let title = required_title(arguments)?;
        let category_type = arguments
            .optional_category_type("type")?
            .ok_or("Missing required argument 'type'")?;
        let planned = arguments.optional_amount("planned_amount")?.unwrap_or(BWMoneyAmount { value: 0 });
        let accumulated = arguments
            .optional_amount("accumulated_amount")?
            .unwrap_or(BWMoneyAmount { value: 0 });
        let position = arguments.optional_index("position")?;
        let id = Uuid::new_v4();

        let loaded = self.mutate(arguments, |budget| {
            let count = budget
                .categories
                .iter()
                .filter(|category| category.category_type == category_type)
                .count();
            let category = BWCategory {
                id,
                ordinal: count as i32,
                title,
                amount_planned: planned,
                amount_actual: BWMoneyAmount { value: 0 },
                amount_accumulated: accumulated,
                category_type,
                transactions: vec![],
            };
            let budget = domain::create_category(budget, category.clone())?;
            match position {
                Some(position) if position < count => domain::update_category(
                    budget,
                    BWCategory {
                        ordinal: position as i32,
                        ..category
                    },
                ),
                Some(position) if position > count => Err(position_error(position, count + 1)),
                _ => Ok(budget),
            }
        })?;
        Ok(category_json(find_category(&loaded.budget, id)?, false))
    }

    fn update_category(&self, arguments: Arguments) -> ToolResult {
        let id = arguments.required_uuid("category_id")?;
        let title = arguments.optional_str("title")?.map(str::trim).map(str::to_string);
        if title.as_deref().is_some_and(str::is_empty) {
            return Err("Category title cannot be empty".to_string());
        }
        let category_type = arguments.optional_category_type("type")?;
        let planned = arguments.optional_amount("planned_amount")?;
        let accumulated = arguments.optional_amount("accumulated_amount")?;
        let position = arguments.optional_index("position")?;

        let loaded = self.mutate(arguments, |budget| {
            let current = find_category(&budget, id)?.clone();
            let mut updated = BWCategory {
                title: title.unwrap_or(current.title.clone()),
                amount_planned: planned.unwrap_or(current.amount_planned),
                amount_accumulated: accumulated.unwrap_or(current.amount_accumulated),
                category_type: category_type.unwrap_or(current.category_type),
                ..current.clone()
            };
            // A type change appends the category to its new group; apply any
            // requested position as a second step.
            let mut budget = domain::update_category(budget, updated.clone())?;
            if let Some(position) = position {
                let count = budget
                    .categories
                    .iter()
                    .filter(|category| category.category_type == updated.category_type)
                    .count();
                if position >= count {
                    return Err(position_error(position, count));
                }
                updated = find_category(&budget, id)?.clone();
                if updated.ordinal != position as i32 {
                    updated.ordinal = position as i32;
                    budget = domain::update_category(budget, updated)?;
                }
            }
            Ok(budget)
        })?;
        Ok(category_json(find_category(&loaded.budget, id)?, false))
    }

    fn delete_category(&self, arguments: Arguments) -> ToolResult {
        let id = arguments.required_uuid("category_id")?;
        let mut deleted = None;
        self.mutate(arguments, |budget| {
            let category = find_category(&budget, id)?;
            deleted = Some((category.title.clone(), category.transactions.len()));
            domain::delete_category(budget, id)
        })?;
        let (title, transactions) = deleted.unwrap_or_default();
        Ok(json!({
            "deleted_category_id": id.to_string(),
            "title": title,
            "deleted_transaction_count": transactions,
        }))
    }

    // Transactions

    fn list_transactions(&self, arguments: Arguments) -> ToolResult {
        let loaded = self.resolve(arguments)?;
        let category_id = arguments.optional_uuid("category_id")?;
        let category_type = arguments.optional_category_type("type")?;
        let from = arguments.optional_date("from_date")?;
        let to = arguments.optional_date("to_date")?;
        let search = arguments.optional_str("search")?.map(str::to_lowercase);
        let limit = arguments.optional_index("limit")?.unwrap_or(DEFAULT_TRANSACTION_LIMIT);
        let offset = arguments.optional_index("offset")?.unwrap_or(0);
        if let Some(category_id) = category_id {
            find_category(&loaded.budget, category_id)?;
        }

        let mut matches: Vec<(&BWCategory, &BWTransaction)> = loaded
            .budget
            .categories
            .iter()
            .filter(|category| category_id.is_none_or(|id| category.id == id))
            .filter(|category| category_type.is_none_or(|kind| category.category_type == kind))
            .flat_map(|category| category.transactions.iter().map(move |transaction| (category, transaction)))
            .filter(|(_, transaction)| from.is_none_or(|from| transaction.date >= from))
            .filter(|(_, transaction)| to.is_none_or(|to| transaction.date <= to))
            .filter(|(_, transaction)| {
                search.as_deref().is_none_or(|search| {
                    transaction.title.to_lowercase().contains(search)
                        || transaction.description.to_lowercase().contains(search)
                })
            })
            .collect();
        matches.sort_by(|(_, left), (_, right)| {
            right.date.cmp(&left.date).then_with(|| left.title.cmp(&right.title))
        });

        let total = matches.len();
        let transactions: Vec<Value> = matches
            .into_iter()
            .skip(offset)
            .take(limit)
            .map(|(category, transaction)| transaction_json(transaction, Some(category)))
            .collect();
        Ok(json!({
            "budget": loaded.location,
            "total_count": total,
            "offset": offset,
            "transactions": transactions,
        }))
    }

    fn create_transaction(&self, arguments: Arguments) -> ToolResult {
        let category_id = arguments.required_uuid("category_id")?;
        let title = required_title(arguments)?;
        let amount = arguments.optional_amount("amount")?.ok_or("Missing required argument 'amount'")?;
        let date = arguments.optional_date("date")?;
        let description = arguments.optional_str("description")?.map(str::to_string);
        let transaction = crate::models::new_transaction(title, description, date, amount)?;
        let id = transaction.id;

        let loaded = self.mutate(arguments, |budget| {
            domain::create_transaction(budget, category_id, transaction)
        })?;
        let (category, transaction) = find_transaction(&loaded.budget, id)?;
        Ok(transaction_json(transaction, Some(category)))
    }

    fn update_transaction(&self, arguments: Arguments) -> ToolResult {
        let id = arguments.required_uuid("transaction_id")?;
        let title = arguments.optional_str("title")?.map(str::trim).map(str::to_string);
        if title.as_deref().is_some_and(str::is_empty) {
            return Err("Transaction title cannot be empty".to_string());
        }
        let description = arguments.optional_str("description")?.map(str::to_string);
        let amount = arguments.optional_amount("amount")?;
        let date = arguments.optional_date("date")?;
        let target_category = arguments.optional_uuid("category_id")?;

        let loaded = self.mutate(arguments, |budget| {
            let (category, current) = find_transaction(&budget, id)?;
            let category_id = category.id;
            let updated = BWTransaction {
                id,
                title: title.unwrap_or(current.title.clone()),
                description: description.unwrap_or(current.description.clone()),
                date: date.unwrap_or(current.date),
                amount: amount.unwrap_or(current.amount),
            };
            let budget = domain::update_transaction(budget, category_id, updated)?;
            match target_category {
                Some(target) if target != category_id => {
                    find_category(&budget, target)?;
                    domain::move_transaction(budget, category_id, target, id)
                }
                _ => Ok(budget),
            }
        })?;
        let (category, transaction) = find_transaction(&loaded.budget, id)?;
        Ok(transaction_json(transaction, Some(category)))
    }

    fn delete_transaction(&self, arguments: Arguments) -> ToolResult {
        let id = arguments.required_uuid("transaction_id")?;
        let mut deleted = None;
        self.mutate(arguments, |budget| {
            let (category, transaction) = find_transaction(&budget, id)?;
            deleted = Some(transaction_json(transaction, Some(category)));
            let category_id = category.id;
            domain::delete_transaction(budget, category_id, id)
        })?;
        Ok(json!({ "deleted_transaction": deleted }))
    }
}

// Lookups

fn find_category(budget: &BWBudget, id: Uuid) -> Result<&BWCategory, String> {
    budget
        .categories
        .iter()
        .find(|category| category.id == id)
        .ok_or_else(|| format!("Could not find category with id {id} in this budget"))
}

fn find_transaction(budget: &BWBudget, id: Uuid) -> Result<(&BWCategory, &BWTransaction), String> {
    budget
        .categories
        .iter()
        .find_map(|category| {
            category
                .transactions
                .iter()
                .find(|transaction| transaction.id == id)
                .map(|transaction| (category, transaction))
        })
        .ok_or_else(|| format!("Could not find transaction with id {id} in this budget"))
}

fn transaction_count(budget: &BWBudget) -> usize {
    budget
        .categories
        .iter()
        .map(|category| category.transactions.len())
        .sum()
}

fn position_error(position: usize, count: usize) -> String {
    format!("Position {position} is out of range; this category group allows 0 to {}", count.saturating_sub(1))
}

fn required_title(arguments: Arguments) -> Result<String, String> {
    let title = arguments.required_str("title")?.trim().to_string();
    if title.is_empty() {
        return Err("Title cannot be empty".to_string());
    }
    Ok(title)
}

pub(crate) fn budget_file_name(title: &str) -> String {
    let cleaned: String = title
        .trim()
        .chars()
        .map(|character| match character {
            '/' | '\\' | ':' | '*' | '?' | '"' | '<' | '>' | '|' => '-',
            character if character.is_control() => '-',
            character => character,
        })
        .collect();
    let cleaned = cleaned.trim().trim_matches('.');
    let stem = if cleaned.is_empty() { "Untitled Budget" } else { cleaned };
    format!("{stem}.budget")
}

// Serialization

fn money(amount: BWMoneyAmount) -> String {
    format_money_input(amount).unwrap_or_else(|_| amount.value.to_string())
}

fn signed_money(value: i64) -> String {
    let sign = if value < 0 { "-" } else { "" };
    let value = value.unsigned_abs();
    format!("{sign}{}.{:02}", value / 100, value % 100)
}

fn date_string(date: BWDate) -> String {
    format!("{:04}-{:02}-{:02}", date.year, date.month, date.day)
}

fn category_type_name(category_type: BWCategoryType) -> &'static str {
    match category_type {
        BWCategoryType::Income => "income",
        BWCategoryType::Expenses => "expenses",
        BWCategoryType::Savings => "savings",
        BWCategoryType::Debt => "debt",
    }
}

fn budget_json(location: &str, budget: &BWBudget, is_open: bool, include_transactions: bool) -> Value {
    let categories: Vec<Value> = budget
        .ordered_categories(None)
        .iter()
        .map(|category| category_json(category, include_transactions))
        .collect();
    json!({
        "budget": location,
        "id": budget.id.to_string(),
        "title": budget.title,
        "is_open": is_open,
        "categories": categories,
    })
}

fn category_json(category: &BWCategory, include_transactions: bool) -> Value {
    let mut value = json!({
        "id": category.id.to_string(),
        "title": category.title,
        "type": category_type_name(category.category_type),
        "position": category.ordinal,
        "planned_amount": money(category.amount_planned),
        "actual_amount": money(category.amount_actual),
        "accumulated_amount": money(category.amount_accumulated),
        "transaction_count": category.transactions.len(),
    });
    if include_transactions {
        let mut transactions: Vec<&BWTransaction> = category.transactions.iter().collect();
        transactions.sort_by_key(|transaction| std::cmp::Reverse(transaction.date));
        value["transactions"] = transactions
            .into_iter()
            .map(|transaction| transaction_json(transaction, None))
            .collect();
    }
    value
}

fn transaction_json(transaction: &BWTransaction, category: Option<&BWCategory>) -> Value {
    let mut value = json!({
        "id": transaction.id.to_string(),
        "title": transaction.title,
        "description": transaction.description,
        "date": date_string(transaction.date),
        "amount": money(transaction.amount),
    });
    if let Some(category) = category {
        value["category_id"] = json!(category.id.to_string());
        value["category_title"] = json!(category.title);
        value["category_type"] = json!(category_type_name(category.category_type));
    }
    value
}

fn report_json(budget: &BWBudget) -> ToolResult {
    let summary = build_reporting_summary(budget)?;
    let totals = &summary.totals;
    let mode = |mode: BWReportingAmountMode| match mode {
        BWReportingAmountMode::Planned => "planned",
        BWReportingAmountMode::Actual => "actual",
    };
    let allocation: Vec<Value> = summary
        .allocation_segments
        .iter()
        .map(|segment| {
            json!({
                "mode": mode(segment.amount_mode),
                "type": category_type_name(segment.category_type),
                "amount": money(segment.amount),
            })
        })
        .collect();
    let categories: Vec<Value> = summary
        .category_segments
        .iter()
        .map(|segment| {
            json!({
                "mode": mode(segment.amount_mode),
                "category_id": segment.category_id.to_string(),
                "title": segment.title,
                "type": category_type_name(segment.category_type),
                "amount": money(segment.amount),
            })
        })
        .collect();
    let comparison: Vec<Value> = summary
        .comparison_segments
        .iter()
        .map(|segment| {
            json!({
                "row": match segment.row {
                    BWReportingComparisonRow::Income => "income",
                    BWReportingComparisonRow::Planned => "planned",
                    BWReportingComparisonRow::Actual => "actual",
                },
                "component": match segment.component {
                    BWReportingComponent::Income => "income",
                    BWReportingComponent::Expenses => "expenses",
                    BWReportingComponent::Savings => "savings",
                    BWReportingComponent::Debt => "debt",
                },
                "amount": money(segment.amount),
            })
        })
        .collect();
    Ok(json!({
        "totals": {
            "income": money(totals.income),
            "planned_spending": money(totals.planned_spending),
            "actual_spending": money(totals.actual_spending),
            "planned_savings": money(totals.planned_savings),
            "planned_allocation": money(totals.planned_allocation),
            "actual_allocation": money(totals.actual_allocation),
            "left_to_budget": signed_money(totals.left_to_budget),
        },
        "allocation": allocation,
        "categories": categories,
        "comparison": comparison,
    }))
}

fn list_templates() -> Value {
    let templates: Vec<Value> = template_catalog()
        .into_iter()
        .map(|template| {
            let categories: Vec<Value> = template
                .categories
                .iter()
                .map(|category| {
                    json!({
                        "title": category.title,
                        "type": category_type_name(category.category_type),
                        "planned_amount": money(category.amount_planned),
                    })
                })
                .collect();
            json!({
                "id": template.id,
                "title": template.title,
                "family": template.family,
                "description": template.description,
                "categories": categories,
            })
        })
        .collect();
    json!({ "templates": templates })
}

// Arguments

#[derive(Clone, Copy)]
struct Arguments<'a>(&'a Value);

impl<'a> Arguments<'a> {
    fn value(&self, name: &str) -> Option<&'a Value> {
        self.0.get(name).filter(|value| !value.is_null())
    }

    fn optional_str(&self, name: &str) -> Result<Option<&'a str>, String> {
        match self.value(name) {
            None => Ok(None),
            Some(Value::String(value)) => Ok(Some(value.as_str())),
            Some(_) => Err(format!("Argument '{name}' must be a string")),
        }
    }

    fn required_str(&self, name: &str) -> Result<&'a str, String> {
        self.optional_str(name)?
            .ok_or_else(|| format!("Missing required argument '{name}'"))
    }

    fn optional_bool(&self, name: &str) -> Result<Option<bool>, String> {
        match self.value(name) {
            None => Ok(None),
            Some(Value::Bool(value)) => Ok(Some(*value)),
            Some(_) => Err(format!("Argument '{name}' must be a boolean")),
        }
    }

    fn optional_index(&self, name: &str) -> Result<Option<usize>, String> {
        match self.value(name) {
            None => Ok(None),
            Some(value) => value
                .as_u64()
                .and_then(|value| usize::try_from(value).ok())
                .map(Some)
                .ok_or_else(|| format!("Argument '{name}' must be a non-negative integer")),
        }
    }

    fn optional_uuid(&self, name: &str) -> Result<Option<Uuid>, String> {
        self.optional_str(name)?
            .map(|value| {
                Uuid::parse_str(value.trim()).map_err(|_| format!("Argument '{name}' must be a UUID"))
            })
            .transpose()
    }

    fn required_uuid(&self, name: &str) -> Result<Uuid, String> {
        self.optional_uuid(name)?
            .ok_or_else(|| format!("Missing required argument '{name}'"))
    }

    fn optional_amount(&self, name: &str) -> Result<Option<BWMoneyAmount>, String> {
        let text = match self.value(name) {
            None => return Ok(None),
            Some(Value::String(value)) => value.clone(),
            Some(Value::Number(value)) => value.to_string(),
            Some(_) => return Err(format!("Argument '{name}' must be a decimal amount such as \"12.50\"")),
        };
        if text.trim().is_empty() {
            return Err(format!("Argument '{name}' cannot be empty"));
        }
        parse_money_amount(text.clone(), None).map(Some).ok_or_else(|| {
            format!("Argument '{name}' value '{text}' is not a valid non-negative amount with at most two decimals")
        })
    }

    fn optional_date(&self, name: &str) -> Result<Option<BWDate>, String> {
        self.optional_str(name)?
            .map(|value| {
                let date = NaiveDate::parse_from_str(value.trim(), "%Y-%m-%d")
                    .map_err(|_| format!("Argument '{name}' must be a date in YYYY-MM-DD format"))?;
                use chrono::Datelike;
                Ok(BWDate {
                    year: date.year(),
                    month: date.month() as i32,
                    day: date.day() as i32,
                })
            })
            .transpose()
    }

    fn optional_category_type(&self, name: &str) -> Result<Option<BWCategoryType>, String> {
        self.optional_str(name)?
            .map(|value| match value.trim().to_ascii_lowercase().as_str() {
                "income" => Ok(BWCategoryType::Income),
                "expense" | "expenses" => Ok(BWCategoryType::Expenses),
                "saving" | "savings" => Ok(BWCategoryType::Savings),
                "debt" | "debts" => Ok(BWCategoryType::Debt),
                _ => Err(format!(
                    "Argument '{name}' must be one of income, expenses, savings, debt"
                )),
            })
            .transpose()
    }
}

// Definitions

fn budget_property() -> Value {
    json!({
        "type": "string",
        "description": "The budget's `budget` value from list_budgets, or its id.",
    })
}

fn amount_property(description: &str) -> Value {
    json!({
        "type": "string",
        "pattern": "^[0-9]*([.,][0-9]{1,2})?$",
        "description": description,
    })
}

fn date_property(description: &str) -> Value {
    json!({ "type": "string", "format": "date", "description": description })
}

fn category_type_property() -> Value {
    json!({ "type": "string", "enum": ["income", "expenses", "savings", "debt"] })
}

fn tool(
    name: &str,
    title: &str,
    description: &str,
    properties: Value,
    required: &[&str],
    read_only: bool,
    destructive: bool,
) -> Value {
    json!({
        "name": name,
        "title": title,
        "description": description,
        "inputSchema": {
            "type": "object",
            "properties": properties,
            "required": required,
            "additionalProperties": false,
        },
        "annotations": {
            "title": title,
            "readOnlyHint": read_only,
            "destructiveHint": destructive,
            "idempotentHint": read_only,
            "openWorldHint": false,
        },
    })
}

pub(crate) fn definitions() -> Vec<Value> {
    vec![
        tool(
            "list_budgets",
            "List budgets",
            "Lists the budgets Budget Warden can reach (the open budget and recent budgets), with the display currency.",
            json!({}),
            &[],
            true,
            false,
        ),
        tool(
            "list_templates",
            "List budget templates",
            "Lists the built-in templates that create_budget can start from.",
            json!({}),
            &[],
            true,
            false,
        ),
        tool(
            "create_budget",
            "Create budget",
            "Creates a new budget document from a template (default basic-monthly) or as a copy of an existing budget's categories and planned amounts, without its transactions.",
            json!({
                "title": { "type": "string", "description": "Budget title, also used for the file name." },
                "template_id": { "type": "string", "description": "Template id from list_templates." },
                "copy_from": budget_property(),
                "open_in_app": { "type": "boolean", "description": "Open the new budget in the app. Defaults to false." },
            }),
            &["title"],
            false,
            false,
        ),
        tool(
            "get_budget",
            "Get budget",
            "Returns a budget's title, totals, and categories with planned, actual, and accumulated amounts.",
            json!({
                "budget": budget_property(),
                "include_transactions": { "type": "boolean", "description": "Include each category's transactions. Defaults to false." },
            }),
            &["budget"],
            true,
            false,
        ),
        tool(
            "rename_budget",
            "Rename budget",
            "Changes a budget's title.",
            json!({ "budget": budget_property(), "title": { "type": "string" } }),
            &["budget", "title"],
            false,
            false,
        ),
        tool(
            "open_budget_in_app",
            "Open budget in app",
            "Shows the budget in the Budget Warden app window.",
            json!({ "budget": budget_property() }),
            &["budget"],
            false,
            false,
        ),
        tool(
            "get_report",
            "Get budget report",
            "Returns the budget's reporting summary: totals, allocation by category type, per-category amounts, and the income versus planned and actual comparison.",
            json!({ "budget": budget_property() }),
            &["budget"],
            true,
            false,
        ),
        tool(
            "list_categories",
            "List categories",
            "Lists a budget's categories in display order, optionally only one type.",
            json!({ "budget": budget_property(), "type": category_type_property() }),
            &["budget"],
            true,
            false,
        ),
        tool(
            "get_category",
            "Get category",
            "Returns one category with its transactions.",
            json!({ "budget": budget_property(), "category_id": { "type": "string", "format": "uuid" } }),
            &["budget", "category_id"],
            true,
            false,
        ),
        tool(
            "create_category",
            "Create category",
            "Adds a category to a budget. It is appended to its type group unless a position is given.",
            json!({
                "budget": budget_property(),
                "title": { "type": "string" },
                "type": category_type_property(),
                "planned_amount": amount_property("Planned amount. Defaults to 0."),
                "accumulated_amount": amount_property("Amount accumulated from earlier periods. Defaults to 0."),
                "position": { "type": "integer", "minimum": 0, "description": "Zero-based position within the type group." },
            }),
            &["budget", "title", "type"],
            false,
            false,
        ),
        tool(
            "update_category",
            "Update category",
            "Changes a category's title, type, planned or accumulated amount, or position within its type group. Omitted fields stay unchanged.",
            json!({
                "budget": budget_property(),
                "category_id": { "type": "string", "format": "uuid" },
                "title": { "type": "string" },
                "type": category_type_property(),
                "planned_amount": amount_property("New planned amount."),
                "accumulated_amount": amount_property("New accumulated amount."),
                "position": { "type": "integer", "minimum": 0, "description": "Zero-based position within the type group." },
            }),
            &["budget", "category_id"],
            false,
            false,
        ),
        tool(
            "delete_category",
            "Delete category",
            "Deletes a category and every transaction in it.",
            json!({ "budget": budget_property(), "category_id": { "type": "string", "format": "uuid" } }),
            &["budget", "category_id"],
            false,
            true,
        ),
        tool(
            "list_transactions",
            "List transactions",
            "Lists transactions newest first, optionally filtered by category, category type, date range, or text.",
            json!({
                "budget": budget_property(),
                "category_id": { "type": "string", "format": "uuid" },
                "type": category_type_property(),
                "from_date": date_property("Earliest date, inclusive (YYYY-MM-DD)."),
                "to_date": date_property("Latest date, inclusive (YYYY-MM-DD)."),
                "search": { "type": "string", "description": "Case-insensitive text matched against title and description." },
                "limit": { "type": "integer", "minimum": 0, "description": "Maximum results. Defaults to 200." },
                "offset": { "type": "integer", "minimum": 0, "description": "Results to skip, for paging." },
            }),
            &["budget"],
            true,
            false,
        ),
        tool(
            "create_transaction",
            "Create transaction",
            "Records a transaction in a category. The date defaults to today.",
            json!({
                "budget": budget_property(),
                "category_id": { "type": "string", "format": "uuid" },
                "title": { "type": "string" },
                "amount": amount_property("Transaction amount, such as \"12.50\"."),
                "date": date_property("Transaction date (YYYY-MM-DD)."),
                "description": { "type": "string" },
            }),
            &["budget", "category_id", "title", "amount"],
            false,
            false,
        ),
        tool(
            "update_transaction",
            "Update transaction",
            "Changes a transaction's title, description, amount, or date, or moves it to another category. Omitted fields stay unchanged.",
            json!({
                "budget": budget_property(),
                "transaction_id": { "type": "string", "format": "uuid" },
                "title": { "type": "string" },
                "description": { "type": "string" },
                "amount": amount_property("New amount."),
                "date": date_property("New date (YYYY-MM-DD)."),
                "category_id": { "type": "string", "format": "uuid", "description": "Category to move the transaction to." },
            }),
            &["budget", "transaction_id"],
            false,
            false,
        ),
        tool(
            "delete_transaction",
            "Delete transaction",
            "Deletes a transaction.",
            json!({ "budget": budget_property(), "transaction_id": { "type": "string", "format": "uuid" } }),
            &["budget", "transaction_id"],
            false,
            true,
        ),
    ]
}
