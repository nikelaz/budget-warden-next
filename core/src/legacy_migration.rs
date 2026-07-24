/*
 * Budget Warden
 * Copyright (c) 2026 Lazarov & Co EOOD
 * Author: Nikola Lazarov
 *
 * Licensed under the Source-Available Educational License.
 * See the LICENSE file in the project root for full terms.
 */

use std::collections::{HashMap, HashSet};

use chrono::{Datelike, Local};
use serde::Deserialize;
use serde_json::Value;
use uuid::Uuid;

use crate::crdt::{
    BudgetChange, BudgetChangePayload, CRDTChanges, CRDTOperation, CategoryChange,
    CategoryChangePayload, CategoryField, HlcTimestamp, TransactionChange,
    TransactionChangePayload, TransactionField,
};
use crate::models::{
    BWBudget, BWCategory, BWCategoryType, BWDate, BWMoneyAmount, BWTransaction,
    CURRENT_SCHEMA_VERSION,
};

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct LegacyBudget {
    id: Uuid,
    revision: i64,
    revision_id: Uuid,
    categories: Vec<LegacyCategory>,
    title: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct LegacyCategory {
    ordinal: i32,
    amount_actual: i64,
    amount_planned: i64,
    transactions: Vec<LegacyTransaction>,
    amount_accumulated: i64,
    category_type: i32,
    id: Uuid,
    title: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct LegacyTransaction {
    id: Uuid,
    title: String,
    description: String,
    date: String,
    amount: i64,
}

// TEMPORARY LEGACY MIGRATION:
// Remove this function and module, the fallback in codec::decode_budget,
// BWBudget::requires_migration_writeback, and the macOS writeback branch after
// all live schema-v1 budgets have been opened by the schema-v2 app.
pub(crate) fn migrate_legacy_budget(value: Value, url: String) -> Result<BWBudget, String> {
    let legacy: LegacyBudget = serde_json::from_value(value)
        .map_err(|error| format!("Failed to migrate legacy budget JSON: {error}"))?;

    if legacy.revision < 0 {
        return Err(
            "Failed to migrate legacy budget JSON: revision cannot be negative".to_string(),
        );
    }

    let baseline_logical = i32::try_from(legacy.revision).map_err(|_| {
        "Failed to migrate legacy budget JSON: revision is too large for CRDT migration".to_string()
    })?;
    let migrated_revision = legacy.revision.checked_add(1).ok_or_else(|| {
        "Failed to migrate legacy budget JSON: revision cannot be advanced".to_string()
    })?;
    let baseline_timestamp = HlcTimestamp {
        physical_ms: 0,
        logical: baseline_logical,
        device_id: legacy.revision_id,
    };

    let mut category_ids = HashSet::new();
    let mut transaction_ids = HashSet::new();
    let mut categories = Vec::with_capacity(legacy.categories.len());
    let mut category_changes = HashMap::new();
    let mut transaction_changes = HashMap::new();

    for legacy_category in legacy.categories {
        if !category_ids.insert(legacy_category.id) {
            return Err(format!(
                "Failed to migrate legacy budget JSON: duplicate category id {}",
                legacy_category.id
            ));
        }
        if legacy_category.amount_actual < 0
            || legacy_category.amount_planned < 0
            || legacy_category.amount_accumulated < 0
        {
            return Err(format!(
                "Failed to migrate legacy budget JSON: category {} contains a negative money amount",
                legacy_category.id
            ));
        }

        let category_type = match legacy_category.category_type {
            1 => BWCategoryType::Income,
            2 => BWCategoryType::Expenses,
            3 => BWCategoryType::Savings,
            4 => BWCategoryType::Debt,
            value => {
                return Err(format!(
                    "Failed to migrate legacy budget JSON: unsupported category type {value}"
                ));
            }
        };

        let mut transactions = Vec::with_capacity(legacy_category.transactions.len());
        let mut amount_actual = 0_i64;

        for legacy_transaction in legacy_category.transactions {
            if !transaction_ids.insert(legacy_transaction.id) {
                return Err(format!(
                    "Failed to migrate legacy budget JSON: duplicate transaction id {}",
                    legacy_transaction.id
                ));
            }
            if legacy_transaction.amount < 0 {
                return Err(format!(
                    "Failed to migrate legacy budget JSON: transaction {} contains a negative money amount",
                    legacy_transaction.id
                ));
            }

            let parsed_date = chrono::DateTime::parse_from_rfc3339(&legacy_transaction.date)
                .map_err(|error| {
                    format!(
                        "Failed to migrate legacy budget JSON: invalid date for transaction {}: {error}",
                        legacy_transaction.id
                    )
                })?
                .with_timezone(&Local);
            let transaction = BWTransaction {
                id: legacy_transaction.id,
                title: legacy_transaction.title,
                description: legacy_transaction.description,
                date: BWDate {
                    year: parsed_date.year(),
                    month: parsed_date.month() as i32,
                    day: parsed_date.day() as i32,
                },
                amount: BWMoneyAmount {
                    value: legacy_transaction.amount,
                },
            };

            amount_actual = amount_actual
                .checked_add(transaction.amount.value)
                .ok_or_else(|| {
                    format!(
                        "Failed to migrate legacy budget JSON: actual amount overflow in category {}",
                        legacy_category.id
                    )
                })?;

            transaction_changes.insert(
                transaction.id,
                HashMap::from([
                    (
                        TransactionField::Category,
                        TransactionChange {
                            change_id: Uuid::new_v4(),
                            timestamp: baseline_timestamp.clone(),
                            operation: CRDTOperation::Create,
                            category_id: legacy_category.id,
                            transaction_id: transaction.id,
                            payload: None,
                        },
                    ),
                    (
                        TransactionField::Title,
                        TransactionChange {
                            change_id: Uuid::new_v4(),
                            timestamp: baseline_timestamp.clone(),
                            operation: CRDTOperation::Create,
                            category_id: legacy_category.id,
                            transaction_id: transaction.id,
                            payload: Some(TransactionChangePayload {
                                title: Some(transaction.title.clone()),
                                description: None,
                                date: None,
                                amount: None,
                            }),
                        },
                    ),
                    (
                        TransactionField::Description,
                        TransactionChange {
                            change_id: Uuid::new_v4(),
                            timestamp: baseline_timestamp.clone(),
                            operation: CRDTOperation::Create,
                            category_id: legacy_category.id,
                            transaction_id: transaction.id,
                            payload: Some(TransactionChangePayload {
                                title: None,
                                description: Some(transaction.description.clone()),
                                date: None,
                                amount: None,
                            }),
                        },
                    ),
                    (
                        TransactionField::Date,
                        TransactionChange {
                            change_id: Uuid::new_v4(),
                            timestamp: baseline_timestamp.clone(),
                            operation: CRDTOperation::Create,
                            category_id: legacy_category.id,
                            transaction_id: transaction.id,
                            payload: Some(TransactionChangePayload {
                                title: None,
                                description: None,
                                date: Some(transaction.date),
                                amount: None,
                            }),
                        },
                    ),
                    (
                        TransactionField::Amount,
                        TransactionChange {
                            change_id: Uuid::new_v4(),
                            timestamp: baseline_timestamp.clone(),
                            operation: CRDTOperation::Create,
                            category_id: legacy_category.id,
                            transaction_id: transaction.id,
                            payload: Some(TransactionChangePayload {
                                title: None,
                                description: None,
                                date: None,
                                amount: Some(transaction.amount),
                            }),
                        },
                    ),
                ]),
            );
            transactions.push(transaction);
        }

        let category = BWCategory {
            id: legacy_category.id,
            ordinal: legacy_category.ordinal,
            title: legacy_category.title,
            amount_planned: BWMoneyAmount {
                value: legacy_category.amount_planned,
            },
            amount_actual: BWMoneyAmount {
                value: amount_actual,
            },
            amount_accumulated: BWMoneyAmount {
                value: legacy_category.amount_accumulated,
            },
            category_type,
            transactions,
        };

        category_changes.insert(
            category.id,
            HashMap::from([
                (
                    CategoryField::Ordinal,
                    CategoryChange {
                        change_id: Uuid::new_v4(),
                        timestamp: baseline_timestamp.clone(),
                        operation: CRDTOperation::Create,
                        category_id: category.id,
                        payload: Some(CategoryChangePayload {
                            ordinal: Some(category.ordinal),
                            title: None,
                            amount_planned: None,
                            amount_accumulated: None,
                            category_type: None,
                        }),
                    },
                ),
                (
                    CategoryField::Title,
                    CategoryChange {
                        change_id: Uuid::new_v4(),
                        timestamp: baseline_timestamp.clone(),
                        operation: CRDTOperation::Create,
                        category_id: category.id,
                        payload: Some(CategoryChangePayload {
                            ordinal: None,
                            title: Some(category.title.clone()),
                            amount_planned: None,
                            amount_accumulated: None,
                            category_type: None,
                        }),
                    },
                ),
                (
                    CategoryField::AmountPlanned,
                    CategoryChange {
                        change_id: Uuid::new_v4(),
                        timestamp: baseline_timestamp.clone(),
                        operation: CRDTOperation::Create,
                        category_id: category.id,
                        payload: Some(CategoryChangePayload {
                            ordinal: None,
                            title: None,
                            amount_planned: Some(category.amount_planned),
                            amount_accumulated: None,
                            category_type: None,
                        }),
                    },
                ),
                (
                    CategoryField::AmountAccumulated,
                    CategoryChange {
                        change_id: Uuid::new_v4(),
                        timestamp: baseline_timestamp.clone(),
                        operation: CRDTOperation::Create,
                        category_id: category.id,
                        payload: Some(CategoryChangePayload {
                            ordinal: None,
                            title: None,
                            amount_planned: None,
                            amount_accumulated: Some(category.amount_accumulated),
                            category_type: None,
                        }),
                    },
                ),
                (
                    CategoryField::CategoryType,
                    CategoryChange {
                        change_id: Uuid::new_v4(),
                        timestamp: baseline_timestamp.clone(),
                        operation: CRDTOperation::Create,
                        category_id: category.id,
                        payload: Some(CategoryChangePayload {
                            ordinal: None,
                            title: None,
                            amount_planned: None,
                            amount_accumulated: None,
                            category_type: Some(category.category_type),
                        }),
                    },
                ),
            ]),
        );
        categories.push(category);
    }

    let title = legacy.title;
    Ok(BWBudget {
        id: legacy.id,
        revision: migrated_revision,
        revision_id: Uuid::new_v4(),
        schema_version: CURRENT_SCHEMA_VERSION,
        title: title.clone(),
        categories,
        changes: CRDTChanges {
            budget: vec![BudgetChange {
                change_id: Uuid::new_v4(),
                timestamp: baseline_timestamp,
                payload: Some(BudgetChangePayload { title: Some(title) }),
            }],
            categories: category_changes,
            transactions: transaction_changes,
            category_tombstones: HashMap::new(),
            transaction_tombstones: HashMap::new(),
        },
        url: Some(url),
        requires_migration_writeback: true,
    })
}
