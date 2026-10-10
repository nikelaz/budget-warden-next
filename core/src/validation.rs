/*
 * Budget Warden
 * Copyright (c) 2026 Lazarov & Co EOOD
 * Author: Nikola Lazarov
 *
 * Licensed under the Source-Available Educational License.
 * See the LICENSE file in the project root for full terms.
 */

use std::collections::{HashMap, HashSet};

use boltffi::*;
use chrono::NaiveDate;
use uuid::Uuid;

use crate::crdt::{
    BudgetChange, CategoryChange, CategoryField, HlcTimestamp, TransactionChange, TransactionField,
};
use crate::models::{BWBudget, BWCategory, BWMoneyAmount, BWTransaction, CURRENT_SCHEMA_VERSION};

pub(crate) fn validate_money_amount(amount: BWMoneyAmount, context: &str) -> Result<(), String> {
    if amount.value < 0 {
        return Err(format!("{context} cannot be negative"));
    }

    Ok(())
}

pub(crate) fn checked_money_sum<I>(amounts: I, context: &str) -> Result<BWMoneyAmount, String>
where
    I: IntoIterator<Item = BWMoneyAmount>,
{
    let value = amounts.into_iter().try_fold(0_i64, |total, amount| {
        validate_money_amount(amount, context)?;
        total
            .checked_add(amount.value)
            .ok_or_else(|| format!("{context} is too large"))
    })?;

    Ok(BWMoneyAmount { value })
}

pub(crate) fn validate_derived_totals(budget: &BWBudget) -> Result<(), String> {
    for category in &budget.categories {
        let actual = checked_money_sum(
            category
                .transactions
                .iter()
                .map(|transaction| transaction.amount),
            &format!("Category {} transaction total", category.id),
        )?;
        if category.amount_actual != actual {
            return Err(format!(
                "Category {} actual amount does not match its transactions",
                category.id
            ));
        }
    }
    Ok(())
}

fn validate_timestamp(timestamp: &HlcTimestamp, context: &str) -> Result<(), String> {
    if timestamp.physical_ms < 0 {
        return Err(format!("{context} physical time cannot be negative"));
    }
    if timestamp.logical < 0 {
        return Err(format!("{context} logical time cannot be negative"));
    }
    if timestamp.device_id.is_nil() {
        return Err(format!("{context} device ID cannot be empty"));
    }

    Ok(())
}

pub(crate) fn validate_category(category: &BWCategory) -> Result<(), String> {
    if category.id.is_nil() {
        return Err("Category ID cannot be empty".to_string());
    }
    if category.ordinal < 0 {
        return Err(format!(
            "Category {} ordinal cannot be negative",
            category.id
        ));
    }
    if category.title.trim().is_empty() {
        return Err(format!("Category {} title cannot be empty", category.id));
    }

    validate_money_amount(
        category.amount_planned,
        &format!("Category {} planned amount", category.id),
    )?;
    validate_money_amount(
        category.amount_actual,
        &format!("Category {} actual amount", category.id),
    )?;
    validate_money_amount(
        category.amount_accumulated,
        &format!("Category {} accumulated amount", category.id),
    )?;

    let mut transaction_ids = HashSet::new();
    for transaction in &category.transactions {
        if transaction.id.is_nil() {
            return Err("Transaction ID cannot be empty".to_string());
        }
        if !transaction_ids.insert(transaction.id) {
            return Err(format!("Duplicate transaction ID {}", transaction.id));
        }
        if NaiveDate::from_ymd_opt(
            transaction.date.year,
            transaction.date.month as u32,
            transaction.date.day as u32,
        )
        .is_none()
        {
            return Err(format!(
                "Transaction {} has an invalid calendar date",
                transaction.id
            ));
        }
    }
    checked_money_sum(
        category
            .transactions
            .iter()
            .map(|transaction| transaction.amount),
        &format!("Category {} transaction total", category.id),
    )?;

    Ok(())
}

fn one_payload_field(values: &[bool], context: &str) -> Result<(), String> {
    if values.iter().filter(|present| **present).count() != 1 {
        return Err(format!("{context} must contain exactly one field value"));
    }
    Ok(())
}

fn validate_category_change(
    key: Uuid,
    field: &CategoryField,
    change: &CategoryChange,
) -> Result<(), String> {
    if key != change.category_id {
        return Err(format!(
            "Category change key {key} does not match its category ID {}",
            change.category_id
        ));
    }
    if change.change_id.is_nil() {
        return Err(format!("Category {key} has a change with an empty ID"));
    }
    validate_timestamp(&change.timestamp, &format!("Category {key} change"))?;

    let payload = change
        .payload
        .as_ref()
        .ok_or_else(|| format!("Category {key} change has no payload"))?;
    let values = [
        payload.ordinal.is_some(),
        payload.title.is_some(),
        payload.amount_planned.is_some(),
        payload.amount_accumulated.is_some(),
        payload.category_type.is_some(),
    ];
    one_payload_field(&values, &format!("Category {key} change"))?;
    let field_matches = match field {
        CategoryField::Ordinal => values[0],
        CategoryField::Title => values[1],
        CategoryField::AmountPlanned => values[2],
        CategoryField::AmountAccumulated => values[3],
        CategoryField::CategoryType => values[4],
    };
    if !field_matches {
        return Err(format!(
            "Category {key} change payload does not match its field"
        ));
    }

    if payload.ordinal.is_some_and(|ordinal| ordinal < 0) {
        return Err(format!("Category {key} ordinal cannot be negative"));
    }
    if let Some(title) = &payload.title {
        if title.trim().is_empty() {
            return Err(format!("Category {key} title cannot be empty"));
        }
    }
    if let Some(amount) = payload.amount_planned {
        validate_money_amount(amount, "Category planned amount")?;
    }
    if let Some(amount) = payload.amount_accumulated {
        validate_money_amount(amount, "Category accumulated amount")?;
    }

    Ok(())
}

fn category_change_matches(
    category: &BWCategory,
    field: &CategoryField,
    change: &CategoryChange,
) -> bool {
    let Some(payload) = &change.payload else {
        return false;
    };
    match field {
        CategoryField::Ordinal => payload.ordinal == Some(category.ordinal),
        CategoryField::Title => payload.title.as_deref() == Some(category.title.as_str()),
        CategoryField::AmountPlanned => payload.amount_planned == Some(category.amount_planned),
        CategoryField::AmountAccumulated => {
            payload.amount_accumulated == Some(category.amount_accumulated)
        }
        CategoryField::CategoryType => payload.category_type == Some(category.category_type),
    }
}

fn validate_transaction_change(
    key: Uuid,
    field: &TransactionField,
    change: &TransactionChange,
    category_ids: &HashSet<Uuid>,
    category_tombstones: &HashMap<Uuid, HlcTimestamp>,
) -> Result<(), String> {
    if key != change.transaction_id {
        return Err(format!(
            "Transaction change key {key} does not match its transaction ID {}",
            change.transaction_id
        ));
    }
    if change.change_id.is_nil() {
        return Err(format!("Transaction {key} has a change with an empty ID"));
    }
    if !category_ids.contains(&change.category_id)
        && !category_tombstones.contains_key(&change.category_id)
    {
        return Err(format!(
            "Transaction {key} change references unknown category {}",
            change.category_id
        ));
    }
    validate_timestamp(&change.timestamp, &format!("Transaction {key} change"))?;

    let values = if let Some(payload) = &change.payload {
        [
            payload.title.is_some(),
            payload.description.is_some(),
            payload.date.is_some(),
            payload.amount.is_some(),
        ]
    } else {
        [false; 4]
    };
    match field {
        TransactionField::Category => {
            if change.payload.is_some() {
                return Err(format!(
                    "Transaction {key} category change must not have a payload"
                ));
            }
        }
        _ => {
            one_payload_field(&values, &format!("Transaction {key} change"))?;
            let field_matches = match field {
                TransactionField::Title => values[0],
                TransactionField::Description => values[1],
                TransactionField::Date => values[2],
                TransactionField::Amount => values[3],
                TransactionField::Category => unreachable!(),
            };
            if !field_matches {
                return Err(format!(
                    "Transaction {key} change payload does not match its field"
                ));
            }
            if let Some(payload) = &change.payload {
                if let Some(date) = payload.date {
                    if NaiveDate::from_ymd_opt(date.year, date.month as u32, date.day as u32)
                        .is_none()
                    {
                        return Err(format!("Transaction {key} has an invalid calendar date"));
                    }
                }
                if let Some(amount) = payload.amount {
                    validate_money_amount(amount, "Transaction amount")?;
                }
            }
        }
    }

    Ok(())
}

fn validate_budget_change(change: &BudgetChange) -> Result<(), String> {
    if change.change_id.is_nil() {
        return Err("Budget has a change with an empty ID".to_string());
    }
    validate_timestamp(&change.timestamp, "Budget change")?;
    let title = change
        .payload
        .as_ref()
        .and_then(|payload| payload.title.as_deref())
        .ok_or_else(|| "Budget title change has no title".to_string())?;
    if title.trim().is_empty() {
        return Err("Budget title cannot be empty".to_string());
    }
    Ok(())
}

fn transaction_change_matches(
    transaction: &BWTransaction,
    field: &TransactionField,
    change: &TransactionChange,
    current_category_id: Uuid,
) -> bool {
    match field {
        TransactionField::Category => change.category_id == current_category_id,
        TransactionField::Title => {
            change
                .payload
                .as_ref()
                .and_then(|payload| payload.title.as_deref())
                == Some(transaction.title.as_str())
        }
        TransactionField::Description => {
            change
                .payload
                .as_ref()
                .and_then(|payload| payload.description.as_deref())
                == Some(transaction.description.as_str())
        }
        TransactionField::Date => {
            change.payload.as_ref().and_then(|payload| payload.date) == Some(transaction.date)
        }
        TransactionField::Amount => {
            change.payload.as_ref().and_then(|payload| payload.amount) == Some(transaction.amount)
        }
    }
}

#[export]
pub fn validate_budget(budget: &BWBudget) -> Result<(), String> {
    if budget.id.is_nil() {
        return Err("Budget ID cannot be empty".to_string());
    }
    if budget.revision < 0 {
        return Err("Budget revision cannot be negative".to_string());
    }
    if budget.revision_id.is_nil() {
        return Err("Budget revision ID cannot be empty".to_string());
    }
    if budget.schema_version != CURRENT_SCHEMA_VERSION {
        return Err(format!(
            "Unsupported budget schema version {}; supported version is {}",
            budget.schema_version, CURRENT_SCHEMA_VERSION
        ));
    }
    if budget.title.trim().is_empty() {
        return Err("Budget title cannot be empty".to_string());
    }

    let mut category_ids = HashSet::new();
    let mut categories_by_id = HashMap::new();
    let mut transaction_ids = HashSet::new();
    let mut transaction_categories = HashMap::new();
    let mut transactions_by_id = HashMap::new();

    for category in &budget.categories {
        if !category_ids.insert(category.id) {
            return Err(format!("Duplicate category ID {}", category.id));
        }
        validate_category(category)?;
        categories_by_id.insert(category.id, category);

        for transaction in &category.transactions {
            if transaction.id.is_nil() {
                return Err("Transaction ID cannot be empty".to_string());
            }
            if !transaction_ids.insert(transaction.id) {
                return Err(format!("Duplicate transaction ID {}", transaction.id));
            }
            if NaiveDate::from_ymd_opt(
                transaction.date.year,
                transaction.date.month as u32,
                transaction.date.day as u32,
            )
            .is_none()
            {
                return Err(format!(
                    "Transaction {} has an invalid calendar date",
                    transaction.id
                ));
            }
            validate_money_amount(transaction.amount, "Transaction amount")?;
            transaction_categories.insert(transaction.id, category.id);
            transactions_by_id.insert(transaction.id, transaction);
        }
    }

    for (id, timestamp) in &budget.changes.category_tombstones {
        if id.is_nil() {
            return Err("Category tombstone has an empty ID".to_string());
        }
        if category_ids.contains(id) {
            return Err(format!("Deleted category {id} is still present"));
        }
        validate_timestamp(timestamp, &format!("Category {id} tombstone"))?;
    }
    for (id, timestamp) in &budget.changes.transaction_tombstones {
        if id.is_nil() {
            return Err("Transaction tombstone has an empty ID".to_string());
        }
        if transaction_ids.contains(id) {
            return Err(format!("Deleted transaction {id} is still present"));
        }
        validate_timestamp(timestamp, &format!("Transaction {id} tombstone"))?;
    }

    for change in &budget.changes.budget {
        validate_budget_change(change)?;
        if change
            .payload
            .as_ref()
            .and_then(|payload| payload.title.as_deref())
            != Some(budget.title.as_str())
        {
            return Err("Budget title change does not match the current title".to_string());
        }
    }
    for (id, fields) in &budget.changes.categories {
        if !category_ids.contains(id) && !budget.changes.category_tombstones.contains_key(id) {
            return Err(format!("Category changes reference unknown category {id}"));
        }
        for (field, change) in fields {
            validate_category_change(*id, field, change)?;
            if let Some(category) = categories_by_id.get(id) {
                if !category_change_matches(category, field, change) {
                    return Err(format!(
                        "Category {id} change does not match its current value"
                    ));
                }
            }
        }
    }
    for (id, fields) in &budget.changes.transactions {
        let category_delete_covers_transaction = fields
            .get(&TransactionField::Category)
            .is_some_and(|change| {
                budget
                    .changes
                    .category_tombstones
                    .contains_key(&change.category_id)
            });
        if !transaction_ids.contains(id)
            && !budget.changes.transaction_tombstones.contains_key(id)
            && !category_delete_covers_transaction
        {
            return Err(format!(
                "Transaction changes reference unknown transaction {id}"
            ));
        }
        for (field, change) in fields {
            validate_transaction_change(
                *id,
                field,
                change,
                &category_ids,
                &budget.changes.category_tombstones,
            )?;
            if let (Some(transaction), Some(category_id)) =
                (transactions_by_id.get(id), transaction_categories.get(id))
            {
                if !transaction_change_matches(transaction, field, change, *category_id) {
                    return Err(format!(
                        "Transaction {id} change does not match its current value"
                    ));
                }
            }
        }
    }

    Ok(())
}
