/*
 * Budget Warden
 * Copyright (c) 2026 Lazarov & Co EOOD
 * Author: Nikola Lazarov
 *
 * Licensed under the Source-Available Educational License.
 * See the LICENSE file in the project root for full terms.
 */

use crate::app_state::*;
use crate::models::*;
use boltffi::*;
use chrono::Utc;
use serde::{Deserialize, Serialize};
use std::cmp::Ordering;
use std::collections::HashMap;
use uuid::Uuid;

#[data]
#[derive(Clone, Serialize, Deserialize, Eq, PartialEq, Ord, PartialOrd)]
#[serde(deny_unknown_fields)]
pub struct HlcTimestamp {
    pub physical_ms: i64,
    pub logical: i32,
    pub device_id: Uuid,
}

impl HlcTimestamp {
    pub fn now() -> Result<Self, String> {
        let state =
            initialized_app_state().ok_or_else(|| "Rust core is not initialized".to_string())?;
        let mut last = state
            .last_hlc
            .lock()
            .map_err(|_| "Clock state is unavailable".to_string())?;
        let now_ms = Utc::now().timestamp_millis();

        let ts = if now_ms > last.physical_ms {
            Self {
                physical_ms: now_ms,
                logical: 0,
                device_id: state.device_id,
            }
        } else if let Some(logical) = last.logical.checked_add(1) {
            Self {
                physical_ms: last.physical_ms,
                logical,
                device_id: state.device_id,
            }
        } else if let Some(physical_ms) = last.physical_ms.checked_add(1) {
            // Advancing the physical component by one preserves HLC ordering
            // when the logical counter is exhausted.
            Self {
                physical_ms,
                logical: 0,
                device_id: state.device_id,
            }
        } else {
            return Err(
                "The observed clock is too far in the future to create a new change".to_string(),
            );
        };

        *last = ts.clone();
        Ok(ts)
    }

    pub(crate) fn observe(observed: &Self) -> Result<(), String> {
        let Some(state) = initialized_app_state() else {
            return Ok(());
        };
        let mut last = state
            .last_hlc
            .lock()
            .map_err(|_| "Clock state is unavailable".to_string())?;

        if observed.physical_ms > last.physical_ms {
            last.physical_ms = observed.physical_ms;
            last.logical = observed.logical;
        } else if observed.physical_ms == last.physical_ms {
            last.logical = last.logical.max(observed.logical);
        }

        // The local clock advances from the observed physical/logical value,
        // but locally-created changes must retain this device's identity.
        last.device_id = state.device_id;
        Ok(())
    }
}

#[data]
#[derive(Clone, Serialize, Deserialize)]
pub enum CRDTOperation {
    Create,
    Update,
}

#[data]
#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct TransactionChangePayload {
    pub title: Option<String>,
    pub description: Option<String>,
    pub date: Option<BWDate>,
    pub amount: Option<BWMoneyAmount>,
}

#[data]
#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct TransactionChange {
    pub change_id: Uuid,
    pub timestamp: HlcTimestamp,
    pub operation: CRDTOperation,
    pub category_id: Uuid,
    pub transaction_id: Uuid,
    pub payload: Option<TransactionChangePayload>,
}

pub fn new_change_transaction_create(
    category_id: Uuid,
    transaction: BWTransaction,
) -> Result<HashMap<TransactionField, TransactionChange>, String> {
    let mut map = HashMap::new();

    map.insert(
        TransactionField::Category,
        TransactionChange {
            change_id: Uuid::new_v4(),
            timestamp: HlcTimestamp::now()?,
            operation: CRDTOperation::Create,
            category_id,
            transaction_id: transaction.id,
            payload: None,
        },
    );

    map.insert(
        TransactionField::Title,
        TransactionChange {
            change_id: Uuid::new_v4(),
            timestamp: HlcTimestamp::now()?,
            operation: CRDTOperation::Create,
            category_id,
            transaction_id: transaction.id,
            payload: Some(TransactionChangePayload {
                title: Some(transaction.title),
                description: None,
                date: None,
                amount: None,
            }),
        },
    );

    map.insert(
        TransactionField::Description,
        TransactionChange {
            change_id: Uuid::new_v4(),
            timestamp: HlcTimestamp::now()?,
            operation: CRDTOperation::Create,
            category_id,
            transaction_id: transaction.id,
            payload: Some(TransactionChangePayload {
                title: None,
                description: Some(transaction.description),
                date: None,
                amount: None,
            }),
        },
    );

    map.insert(
        TransactionField::Date,
        TransactionChange {
            change_id: Uuid::new_v4(),
            timestamp: HlcTimestamp::now()?,
            operation: CRDTOperation::Create,
            category_id,
            transaction_id: transaction.id,
            payload: Some(TransactionChangePayload {
                title: None,
                description: None,
                date: Some(transaction.date),
                amount: None,
            }),
        },
    );

    map.insert(
        TransactionField::Amount,
        TransactionChange {
            change_id: Uuid::new_v4(),
            timestamp: HlcTimestamp::now()?,
            operation: CRDTOperation::Create,
            category_id,
            transaction_id: transaction.id,
            payload: Some(TransactionChangePayload {
                title: None,
                description: None,
                date: None,
                amount: Some(transaction.amount),
            }),
        },
    );

    Ok(map)
}

pub fn new_change_transaction_update(
    category_id: Uuid,
    transaction: BWTransaction,
    field: TransactionField,
) -> Result<TransactionChange, String> {
    let payload = match field {
        TransactionField::Title => Some(TransactionChangePayload {
            title: Some(transaction.title),
            description: None,
            date: None,
            amount: None,
        }),
        TransactionField::Description => Some(TransactionChangePayload {
            title: None,
            description: Some(transaction.description),
            date: None,
            amount: None,
        }),
        TransactionField::Date => Some(TransactionChangePayload {
            title: None,
            description: None,
            date: Some(transaction.date),
            amount: None,
        }),
        TransactionField::Amount => Some(TransactionChangePayload {
            title: None,
            description: None,
            date: None,
            amount: Some(transaction.amount),
        }),
        TransactionField::Category => None,
    };

    Ok(TransactionChange {
        change_id: Uuid::new_v4(),
        timestamp: HlcTimestamp::now()?,
        operation: CRDTOperation::Update,
        category_id,
        transaction_id: transaction.id,
        payload,
    })
}

pub fn new_change_category_create(
    category: BWCategory,
) -> Result<HashMap<CategoryField, CategoryChange>, String> {
    let mut map = HashMap::new();

    map.insert(
        CategoryField::Ordinal,
        CategoryChange {
            change_id: Uuid::new_v4(),
            timestamp: HlcTimestamp::now()?,
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
    );

    map.insert(
        CategoryField::Title,
        CategoryChange {
            change_id: Uuid::new_v4(),
            timestamp: HlcTimestamp::now()?,
            operation: CRDTOperation::Create,
            category_id: category.id,
            payload: Some(CategoryChangePayload {
                ordinal: None,
                title: Some(category.title),
                amount_planned: None,
                amount_accumulated: None,
                category_type: None,
            }),
        },
    );

    map.insert(
        CategoryField::AmountPlanned,
        CategoryChange {
            change_id: Uuid::new_v4(),
            timestamp: HlcTimestamp::now()?,
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
    );

    map.insert(
        CategoryField::AmountAccumulated,
        CategoryChange {
            change_id: Uuid::new_v4(),
            timestamp: HlcTimestamp::now()?,
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
    );

    map.insert(
        CategoryField::CategoryType,
        CategoryChange {
            change_id: Uuid::new_v4(),
            timestamp: HlcTimestamp::now()?,
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
    );

    Ok(map)
}

pub fn new_change_category_update(
    category: BWCategory,
    field: CategoryField,
) -> Result<CategoryChange, String> {
    let payload = match field {
        CategoryField::Ordinal => CategoryChangePayload {
            ordinal: Some(category.ordinal),
            title: None,
            amount_planned: None,
            amount_accumulated: None,
            category_type: None,
        },
        CategoryField::Title => CategoryChangePayload {
            ordinal: None,
            title: Some(category.title),
            amount_planned: None,
            amount_accumulated: None,
            category_type: None,
        },
        CategoryField::AmountPlanned => CategoryChangePayload {
            ordinal: None,
            title: None,
            amount_planned: Some(category.amount_planned),
            amount_accumulated: None,
            category_type: None,
        },
        CategoryField::AmountAccumulated => CategoryChangePayload {
            ordinal: None,
            title: None,
            amount_planned: None,
            amount_accumulated: Some(category.amount_accumulated),
            category_type: None,
        },
        CategoryField::CategoryType => CategoryChangePayload {
            ordinal: None,
            title: None,
            amount_planned: None,
            amount_accumulated: None,
            category_type: Some(category.category_type),
        },
    };

    Ok(CategoryChange {
        change_id: Uuid::new_v4(),
        timestamp: HlcTimestamp::now()?,
        operation: CRDTOperation::Update,
        category_id: category.id,
        payload: Some(payload),
    })
}

#[data]
#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CategoryChangePayload {
    pub ordinal: Option<i32>,
    pub title: Option<String>,
    pub amount_planned: Option<BWMoneyAmount>,
    pub amount_accumulated: Option<BWMoneyAmount>,
    pub category_type: Option<BWCategoryType>,
}

#[data]
#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CategoryChange {
    pub change_id: Uuid,
    pub timestamp: HlcTimestamp,
    pub operation: CRDTOperation,
    pub category_id: Uuid,
    pub payload: Option<CategoryChangePayload>,
}

#[data]
#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct BudgetChangePayload {
    pub title: Option<String>,
}

#[data]
#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct BudgetChange {
    pub change_id: Uuid,
    pub timestamp: HlcTimestamp,
    pub payload: Option<BudgetChangePayload>,
}

#[data]
#[derive(Clone, Eq, PartialEq, Hash, Serialize, Deserialize)]
pub enum CategoryField {
    Ordinal,
    Title,
    AmountPlanned,
    AmountAccumulated,
    CategoryType,
}

#[data]
#[derive(Clone, Eq, PartialEq, Hash, Serialize, Deserialize)]
pub enum TransactionField {
    Title,
    Description,
    Date,
    Amount,
    Category,
}

#[data]
#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CRDTChanges {
    pub budget: Vec<BudgetChange>,
    pub categories: HashMap<Uuid, HashMap<CategoryField, CategoryChange>>,
    pub transactions: HashMap<Uuid, HashMap<TransactionField, TransactionChange>>,
    pub category_tombstones: HashMap<Uuid, HlcTimestamp>,
    pub transaction_tombstones: HashMap<Uuid, HlcTimestamp>,
}

pub(crate) fn observe_budget_timestamps(budget: &BWBudget) -> Result<(), String> {
    for change in &budget.changes.budget {
        HlcTimestamp::observe(&change.timestamp)?;
    }
    for fields in budget.changes.categories.values() {
        for change in fields.values() {
            HlcTimestamp::observe(&change.timestamp)?;
        }
    }
    for fields in budget.changes.transactions.values() {
        for change in fields.values() {
            HlcTimestamp::observe(&change.timestamp)?;
        }
    }
    for timestamp in budget.changes.category_tombstones.values() {
        HlcTimestamp::observe(timestamp)?;
    }
    for timestamp in budget.changes.transaction_tombstones.values() {
        HlcTimestamp::observe(timestamp)?;
    }
    Ok(())
}

fn merge_tombstones(
    mut mem: HashMap<Uuid, HlcTimestamp>,
    disk: HashMap<Uuid, HlcTimestamp>,
) -> HashMap<Uuid, HlcTimestamp> {
    for (id, disk_ts) in disk {
        let should_replace = match mem.get(&id) {
            Some(mem_ts) => disk_ts > *mem_ts,
            None => true,
        };
        if should_replace {
            mem.insert(id, disk_ts);
        }
    }

    mem
}

fn canonical_bytes<T: Serialize>(value: &T) -> Vec<u8> {
    serde_json::to_vec(value).unwrap_or_default()
}

fn compare_change_records<T: Serialize>(
    a_timestamp: &HlcTimestamp,
    a_change_id: Uuid,
    a: &T,
    b_timestamp: &HlcTimestamp,
    b_change_id: Uuid,
    b: &T,
) -> Ordering {
    a_timestamp
        .cmp(b_timestamp)
        .then_with(|| a_change_id.cmp(&b_change_id))
        .then_with(|| canonical_bytes(a).cmp(&canonical_bytes(b)))
}

fn transaction_change_is_greater(a: &TransactionChange, b: &TransactionChange) -> bool {
    compare_change_records(&a.timestamp, a.change_id, a, &b.timestamp, b.change_id, b)
        == Ordering::Greater
}

fn category_change_is_greater(a: &CategoryChange, b: &CategoryChange) -> bool {
    compare_change_records(&a.timestamp, a.change_id, a, &b.timestamp, b.change_id, b)
        == Ordering::Greater
}

fn merge_transaction_changes(
    mut mem: TransactionChangesMap,
    disk: TransactionChangesMap,
) -> TransactionChangesMap {
    for (transaction_id, disk_fields) in disk {
        let field_map = mem.entry(transaction_id).or_insert_with(HashMap::new);
        for (field, disk_change) in disk_fields {
            let should_insert = match field_map.get(&field) {
                Some(existing) => transaction_change_is_greater(&disk_change, existing),
                None => true,
            };
            if should_insert {
                field_map.insert(field, disk_change);
            }
        }
    }
    mem
}

fn merge_budget_changes(mem: Vec<BudgetChange>, disk: Vec<BudgetChange>) -> Vec<BudgetChange> {
    mem.into_iter()
        .chain(disk)
        .max_by(|a, b| {
            compare_change_records(&a.timestamp, a.change_id, a, &b.timestamp, b.change_id, b)
        })
        .into_iter()
        .collect()
}

type CategoryChangesMap = HashMap<Uuid, HashMap<CategoryField, CategoryChange>>;
type TransactionChangesMap = HashMap<Uuid, HashMap<TransactionField, TransactionChange>>;

fn baseline_timestamp(budget_id: Uuid) -> HlcTimestamp {
    HlcTimestamp {
        physical_ms: 0,
        logical: 0,
        // A stable lineage ID makes baselines comparable across replicas.
        device_id: budget_id,
    }
}

pub(crate) fn normalize_budget_changes(mut budget: BWBudget) -> BWBudget {
    let timestamp = baseline_timestamp(budget.id);
    if budget.changes.budget.is_empty() {
        budget.changes.budget.push(BudgetChange {
            change_id: budget.id,
            timestamp: timestamp.clone(),
            payload: Some(BudgetChangePayload {
                title: Some(budget.title.clone()),
            }),
        });
    }

    for category in &budget.categories {
        let fields = budget
            .changes
            .categories
            .entry(category.id)
            .or_insert_with(HashMap::new);
        let mut insert_baseline = |field: CategoryField, payload: CategoryChangePayload| {
            fields.entry(field).or_insert_with(|| CategoryChange {
                change_id: category.id,
                timestamp: timestamp.clone(),
                operation: CRDTOperation::Create,
                category_id: category.id,
                payload: Some(payload),
            });
        };
        insert_baseline(
            CategoryField::Ordinal,
            CategoryChangePayload {
                ordinal: Some(category.ordinal),
                title: None,
                amount_planned: None,
                amount_accumulated: None,
                category_type: None,
            },
        );
        insert_baseline(
            CategoryField::Title,
            CategoryChangePayload {
                ordinal: None,
                title: Some(category.title.clone()),
                amount_planned: None,
                amount_accumulated: None,
                category_type: None,
            },
        );
        insert_baseline(
            CategoryField::AmountPlanned,
            CategoryChangePayload {
                ordinal: None,
                title: None,
                amount_planned: Some(category.amount_planned),
                amount_accumulated: None,
                category_type: None,
            },
        );
        insert_baseline(
            CategoryField::AmountAccumulated,
            CategoryChangePayload {
                ordinal: None,
                title: None,
                amount_planned: None,
                amount_accumulated: Some(category.amount_accumulated),
                category_type: None,
            },
        );
        insert_baseline(
            CategoryField::CategoryType,
            CategoryChangePayload {
                ordinal: None,
                title: None,
                amount_planned: None,
                amount_accumulated: None,
                category_type: Some(category.category_type),
            },
        );

        for transaction in &category.transactions {
            let fields = budget
                .changes
                .transactions
                .entry(transaction.id)
                .or_insert_with(HashMap::new);
            let mut insert_baseline =
                |field: TransactionField, payload: Option<TransactionChangePayload>| {
                    fields.entry(field).or_insert_with(|| TransactionChange {
                        change_id: transaction.id,
                        timestamp: timestamp.clone(),
                        operation: CRDTOperation::Create,
                        category_id: category.id,
                        transaction_id: transaction.id,
                        payload,
                    });
                };
            insert_baseline(TransactionField::Category, None);
            insert_baseline(
                TransactionField::Title,
                Some(TransactionChangePayload {
                    title: Some(transaction.title.clone()),
                    description: None,
                    date: None,
                    amount: None,
                }),
            );
            insert_baseline(
                TransactionField::Description,
                Some(TransactionChangePayload {
                    title: None,
                    description: Some(transaction.description.clone()),
                    date: None,
                    amount: None,
                }),
            );
            insert_baseline(
                TransactionField::Date,
                Some(TransactionChangePayload {
                    title: None,
                    description: None,
                    date: Some(transaction.date),
                    amount: None,
                }),
            );
            insert_baseline(
                TransactionField::Amount,
                Some(TransactionChangePayload {
                    title: None,
                    description: None,
                    date: None,
                    amount: Some(transaction.amount),
                }),
            );
        }
    }

    budget
}

fn merge_category_changes(
    mut mem: CategoryChangesMap,
    disk: CategoryChangesMap,
) -> CategoryChangesMap {
    for (category_id, disk_fields) in disk {
        let field_map = mem.entry(category_id).or_insert_with(HashMap::new);
        for (field, disk_change) in disk_fields {
            let should_insert = match field_map.get(&field) {
                Some(existing) => category_change_is_greater(&disk_change, existing),
                None => true,
            };
            if should_insert {
                field_map.insert(field, disk_change);
            }
        }
    }

    mem
}

fn resolve_budget_title(mem_title: String, changes: &[BudgetChange]) -> String {
    let Some(change) = changes.last() else {
        return mem_title;
    };

    let Some(ref payload) = change.payload else {
        return mem_title;
    };

    payload.title.clone().unwrap_or(mem_title)
}

fn apply_category_changes(cat: &mut BWCategory, changes: &HashMap<CategoryField, CategoryChange>) {
    for (field, change) in changes {
        if let Some(ref payload) = change.payload {
            match field {
                CategoryField::Ordinal => {
                    if let Some(ordinal) = payload.ordinal {
                        cat.ordinal = ordinal;
                    }
                }
                CategoryField::Title => {
                    if let Some(ref title) = payload.title {
                        cat.title = title.clone();
                    }
                }
                CategoryField::AmountPlanned => {
                    if let Some(amount) = payload.amount_planned {
                        cat.amount_planned = amount;
                    }
                }
                CategoryField::AmountAccumulated => {
                    if let Some(amount) = payload.amount_accumulated {
                        cat.amount_accumulated = amount;
                    }
                }
                CategoryField::CategoryType => {
                    if let Some(cat_type) = payload.category_type {
                        cat.category_type = cat_type;
                    }
                }
            }
        }
    }
}

fn apply_transaction_changes(
    tx: &mut BWTransaction,
    changes: &HashMap<TransactionField, TransactionChange>,
) {
    for (field, change) in changes {
        if let Some(ref payload) = change.payload {
            match field {
                TransactionField::Category => {}
                TransactionField::Title => {
                    if let Some(ref title) = payload.title {
                        tx.title = title.clone();
                    }
                }
                TransactionField::Description => {
                    if let Some(ref desc) = payload.description {
                        tx.description = desc.clone();
                    }
                }
                TransactionField::Date => {
                    if let Some(date) = payload.date {
                        tx.date = date;
                    }
                }
                TransactionField::Amount => {
                    if let Some(amount) = payload.amount {
                        tx.amount = amount;
                    }
                }
            }
        }
    }
}

fn transaction_from_changes(
    transaction_id: Uuid,
    fields: &HashMap<TransactionField, TransactionChange>,
) -> Result<(Uuid, BWTransaction), String> {
    let category_id = fields
        .get(&TransactionField::Category)
        .map(|change| change.category_id)
        .ok_or_else(|| format!("Transaction {transaction_id} has no category change"))?;
    let payload_for = |field: &TransactionField| {
        fields
            .get(field)
            .and_then(|change| change.payload.as_ref())
    };
    let title = payload_for(&TransactionField::Title)
        .and_then(|payload| payload.title.clone())
        .ok_or_else(|| format!("Transaction {transaction_id} has no title baseline"))?;
    let description = payload_for(&TransactionField::Description)
        .and_then(|payload| payload.description.clone())
        .ok_or_else(|| format!("Transaction {transaction_id} has no description baseline"))?;
    let date = payload_for(&TransactionField::Date)
        .and_then(|payload| payload.date)
        .ok_or_else(|| format!("Transaction {transaction_id} has no date baseline"))?;
    let amount = payload_for(&TransactionField::Amount)
        .and_then(|payload| payload.amount)
        .ok_or_else(|| format!("Transaction {transaction_id} has no amount baseline"))?;

    Ok((
        category_id,
        BWTransaction {
            id: transaction_id,
            title,
            description,
            date,
            amount,
        },
    ))
}

fn build_merged_categories(
    mem_categories: Vec<BWCategory>,
    disk_categories: Vec<BWCategory>,
    merged_changes: &CRDTChanges,
) -> Result<Vec<BWCategory>, String> {
    let mut tx_by_id: HashMap<Uuid, BWTransaction> = HashMap::new();
    let mut tx_to_cat: HashMap<Uuid, Uuid> = HashMap::new();
    let mut cat_templates: HashMap<Uuid, BWCategory> = HashMap::new();

    for mut cat in mem_categories.into_iter().chain(disk_categories) {
        let cat_id = cat.id;
        for tx in cat.transactions.drain(..) {
            tx_to_cat
                .entry(tx.id)
                .and_modify(|existing| *existing = (*existing).max(cat_id))
                .or_insert(cat_id);
            tx_by_id
                .entry(tx.id)
                .and_modify(|existing| {
                    if canonical_bytes(&tx) > canonical_bytes(existing) {
                        *existing = tx.clone();
                    }
                })
                .or_insert(tx);
        }
        cat_templates
            .entry(cat_id)
            .and_modify(|existing| {
                if canonical_bytes(&cat) > canonical_bytes(existing) {
                    *existing = cat.clone();
                }
            })
            .or_insert(cat);
    }

    // Older snapshots may have deleted a category without writing child
    // transaction tombstones. Keep their full field records so a later
    // explicit move to a surviving category can still materialize the entity.
    for (transaction_id, fields) in &merged_changes.transactions {
        if tx_by_id.contains_key(transaction_id)
            || merged_changes
                .transaction_tombstones
                .contains_key(transaction_id)
        {
            continue;
        }
        let Some(category_change) = fields.get(&TransactionField::Category) else {
            continue;
        };
        if merged_changes
            .category_tombstones
            .contains_key(&category_change.category_id)
        {
            continue;
        }
        if !cat_templates.contains_key(&category_change.category_id) {
            return Err(format!(
                "Transaction {transaction_id} references missing category {}",
                category_change.category_id
            ));
        }
        let (category_id, transaction) = transaction_from_changes(*transaction_id, fields)?;
        tx_to_cat.insert(*transaction_id, category_id);
        tx_by_id.insert(*transaction_id, transaction);
    }

    // Apply transaction changes and group by category, excluding tombstoned
    let mut txs_by_cat: HashMap<Uuid, Vec<BWTransaction>> = HashMap::new();
    for (tx_id, mut tx) in tx_by_id {
        if merged_changes.transaction_tombstones.contains_key(&tx_id) {
            continue;
        }

        let field_changes = merged_changes.transactions.get(&tx_id);
        let category_id = field_changes
            .and_then(|changes| changes.get(&TransactionField::Category))
            .map(|change| change.category_id)
            .or_else(|| tx_to_cat.get(&tx_id).copied());

        if let Some(field_changes) = field_changes {
            apply_transaction_changes(&mut tx, field_changes);
        }

        if let Some(category_id) = category_id {
            if merged_changes.category_tombstones.contains_key(&category_id) {
                continue;
            }
            if !cat_templates.contains_key(&category_id) {
                return Err(format!(
                    "Merged transaction {tx_id} references missing category {category_id}"
                ));
            }
            txs_by_cat
                .entry(category_id)
                .or_insert_with(Vec::new)
                .push(tx);
        }
    }

    // Build result categories, excluding tombstoned
    let mut result: Vec<BWCategory> = Vec::new();
    for (cat_id, mut cat) in cat_templates {
        if merged_changes.category_tombstones.contains_key(&cat_id) {
            continue;
        }
        if let Some(field_changes) = merged_changes.categories.get(&cat_id) {
            apply_category_changes(&mut cat, field_changes);
        }
        let mut txs = txs_by_cat.remove(&cat_id).unwrap_or_default();
        txs.sort_by_key(|transaction| transaction.id);
        cat.amount_actual = crate::validation::checked_money_sum(
            txs.iter().map(|transaction| transaction.amount),
            &format!("Category {cat_id} transaction total"),
        )?;
        cat.transactions = txs;
        result.push(cat);
    }

    if let Some((orphan_category_id, transactions)) =
        txs_by_cat.into_iter().min_by_key(|(category_id, _)| *category_id)
    {
        let transaction_id = transactions.first().map(|transaction| transaction.id);
        return Err(format!(
            "Merged transaction {transaction_id:?} references missing category {orphan_category_id}"
        ));
    }

    result.sort_by_key(|category| (category.category_type as i32, category.ordinal, category.id));
    Ok(result)
}

#[cfg(test)]
fn merge(budget_in_memory: BWBudget, budget_on_disk: BWBudget) -> BWBudget {
    // Simple case: no merge is necessary
    if budget_in_memory.revision_id == budget_on_disk.revision_id {
        return budget_in_memory;
    }

    merge_for_save(budget_in_memory, budget_on_disk)
        .expect("valid in-memory budget reconciliation must succeed")
}

pub(crate) fn merge_for_save(
    budget_in_memory: BWBudget,
    budget_on_disk: BWBudget,
) -> Result<BWBudget, String> {
    // A domain mutation intentionally retains the revision identity of the
    // snapshot it started from. Saving must still merge the mutated snapshot
    // with the current file and mint a new identity, even when the file has
    // not changed since it was opened.
    let mut result = reconcile_semantic(budget_in_memory.clone(), budget_on_disk.clone())?;
    result.revision = budget_in_memory
        .revision
        .max(budget_on_disk.revision)
        .checked_add(1)
        .ok_or_else(|| "Budget revision cannot be advanced".to_string())?;
    result.revision_id = Uuid::new_v4();
    result.url = budget_in_memory.url;
    Ok(result)
}

fn reconcile_semantic(
    budget_in_memory: BWBudget,
    budget_on_disk: BWBudget,
) -> Result<BWBudget, String> {
    if budget_in_memory.id != budget_on_disk.id {
        return Err("Cannot reconcile different budgets".to_string());
    }

    let budget_in_memory = normalize_budget_changes(budget_in_memory);
    let budget_on_disk = normalize_budget_changes(budget_on_disk);
    let merged_changes = CRDTChanges {
        budget: merge_budget_changes(
            budget_in_memory.changes.budget,
            budget_on_disk.changes.budget,
        ),
        categories: merge_category_changes(
            budget_in_memory.changes.categories,
            budget_on_disk.changes.categories,
        ),
        transactions: merge_transaction_changes(
            budget_in_memory.changes.transactions,
            budget_on_disk.changes.transactions,
        ),
        category_tombstones: merge_tombstones(
            budget_in_memory.changes.category_tombstones,
            budget_on_disk.changes.category_tombstones,
        ),
        transaction_tombstones: merge_tombstones(
            budget_in_memory.changes.transaction_tombstones,
            budget_on_disk.changes.transaction_tombstones,
        ),
    };

    let title = resolve_budget_title(budget_in_memory.title, &merged_changes.budget);

    let categories = build_merged_categories(
        budget_in_memory.categories,
        budget_on_disk.categories,
        &merged_changes,
    )?;

    let (revision, revision_id) = if budget_in_memory.revision > budget_on_disk.revision {
        (budget_in_memory.revision, budget_in_memory.revision_id)
    } else if budget_on_disk.revision > budget_in_memory.revision {
        (budget_on_disk.revision, budget_on_disk.revision_id)
    } else {
        (
            budget_in_memory.revision,
            budget_in_memory.revision_id.max(budget_on_disk.revision_id),
        )
    };

    Ok(BWBudget {
        id: budget_in_memory.id,
        revision,
        revision_id,
        schema_version: budget_in_memory
            .schema_version
            .max(budget_on_disk.schema_version),
        title,
        categories,
        changes: merged_changes,
        url: None,
        requires_migration_writeback: false,
    })
}

/// Reconcile two snapshots without changing save revision metadata. The
/// result is deterministic and can be repeated without generating new edits.
#[export]
pub fn reconcile_budget_snapshots(left: BWBudget, right: BWBudget) -> Result<BWBudget, String> {
    crate::validation::validate_budget(&left)?;
    crate::validation::validate_budget(&right)?;
    let result = reconcile_semantic(left, right)?;
    crate::validation::validate_budget(&result)?;
    crate::validation::validate_derived_totals(&result)?;
    Ok(result)
}

/// Compare portable content while ignoring local save bookkeeping.
#[export]
pub fn budget_content_is_equal(left: &BWBudget, right: &BWBudget) -> bool {
    fn content_value(budget: &BWBudget) -> serde_json::Value {
        let mut copy = budget.clone();
        copy.revision = 0;
        copy.revision_id = Uuid::nil();
        copy.url = None;
        copy.requires_migration_writeback = false;
        copy.categories
            .sort_by_key(|category| (category.category_type as i32, category.ordinal, category.id));
        for category in &mut copy.categories {
            category
                .transactions
                .sort_by_key(|transaction| transaction.id);
        }
        serde_json::to_value(copy).unwrap_or(serde_json::Value::Null)
    }

    content_value(left) == content_value(right)
}

// @TODO: These tests are LLM generated and still not reviewed at all
// they are also old, generated before multiple changes to the crdt layer
#[cfg(test)]
mod tests {
    use super::*;
    use uuid::Uuid;

    const DEVICE_A: Uuid = Uuid::from_u128(0xAAAA);
    const DEVICE_B: Uuid = Uuid::from_u128(0xBBBB);

    fn ts(physical_ms: i64, logical: i32, device_id: Uuid) -> HlcTimestamp {
        HlcTimestamp {
            physical_ms,
            logical,
            device_id,
        }
    }

    fn empty_changes() -> CRDTChanges {
        CRDTChanges {
            budget: Vec::new(),
            categories: HashMap::new(),
            transactions: HashMap::new(),
            category_tombstones: HashMap::new(),
            transaction_tombstones: HashMap::new(),
        }
    }

    fn make_budget(
        title: &str,
        revision: i64,
        categories: Vec<BWCategory>,
        changes: CRDTChanges,
    ) -> BWBudget {
        BWBudget {
            id: Uuid::from_u128(1),
            revision,
            revision_id: Uuid::new_v4(),
            schema_version: 2,
            title: title.to_string(),
            categories,
            changes,
            url: Some(String::new()),
            requires_migration_writeback: false,
        }
    }

    fn make_category(
        id: Uuid,
        ordinal: i32,
        title: &str,
        transactions: Vec<BWTransaction>,
    ) -> BWCategory {
        let amount_actual = BWMoneyAmount {
            value: transactions.iter().map(|t| t.amount.value).sum(),
        };
        BWCategory {
            id,
            ordinal,
            title: title.to_string(),
            amount_planned: BWMoneyAmount { value: 0 },
            amount_actual,
            amount_accumulated: BWMoneyAmount { value: 0 },
            category_type: BWCategoryType::Expenses,
            transactions,
        }
    }

    fn make_transaction(id: Uuid, title: &str, amount: i64) -> BWTransaction {
        BWTransaction {
            id,
            title: title.to_string(),
            description: String::new(),
            date: BWDate {
                year: 2026,
                month: 7,
                day: 1,
            },
            amount: BWMoneyAmount { value: amount },
        }
    }

    #[test]
    fn merge_same_revision_returns_mem() {
        let rev_id = Uuid::new_v4();
        let mut mem = make_budget("Mem", 1, vec![], empty_changes());
        mem.revision_id = rev_id;
        let mut disk = make_budget("Disk", 1, vec![], empty_changes());
        disk.revision_id = rev_id;

        let result = merge(mem, disk);
        assert_eq!(result.title, "Mem");
        assert_eq!(result.revision, 1);
    }

    #[test]
    fn merge_revision_is_max_plus_one() {
        let mem = make_budget("B", 3, vec![], empty_changes());
        let disk = make_budget("B", 7, vec![], empty_changes());
        let result = merge(mem, disk);
        assert_eq!(result.revision, 8);
    }

    #[test]
    fn merge_schema_version_takes_max() {
        let mut mem = make_budget("B", 1, vec![], empty_changes());
        mem.schema_version = 2;
        let mut disk = make_budget("B", 1, vec![], empty_changes());
        disk.schema_version = 5;
        let result = merge(mem, disk);
        assert_eq!(result.schema_version, 5);
    }

    #[test]
    fn merge_budget_title_disk_wins_when_newer() {
        let mut mem_changes = empty_changes();
        mem_changes.budget.push(BudgetChange {
            change_id: Uuid::new_v4(),
            timestamp: ts(100, 0, DEVICE_A),
            payload: Some(BudgetChangePayload {
                title: Some("Title A".to_string()),
            }),
        });

        let mut disk_changes = empty_changes();
        disk_changes.budget.push(BudgetChange {
            change_id: Uuid::new_v4(),
            timestamp: ts(200, 0, DEVICE_B),
            payload: Some(BudgetChangePayload {
                title: Some("Title B".to_string()),
            }),
        });

        let mem = make_budget("Original", 1, vec![], mem_changes);
        let disk = make_budget("Original", 1, vec![], disk_changes);
        let result = merge(mem, disk);
        assert_eq!(result.title, "Title B");
    }

    #[test]
    fn merge_budget_title_mem_wins_when_newer() {
        let mut mem_changes = empty_changes();
        mem_changes.budget.push(BudgetChange {
            change_id: Uuid::new_v4(),
            timestamp: ts(300, 0, DEVICE_A),
            payload: Some(BudgetChangePayload {
                title: Some("Title A".to_string()),
            }),
        });

        let mut disk_changes = empty_changes();
        disk_changes.budget.push(BudgetChange {
            change_id: Uuid::new_v4(),
            timestamp: ts(200, 0, DEVICE_B),
            payload: Some(BudgetChangePayload {
                title: Some("Title B".to_string()),
            }),
        });

        let mem = make_budget("Original", 1, vec![], mem_changes);
        let disk = make_budget("Original", 1, vec![], disk_changes);
        let result = merge(mem, disk);
        assert_eq!(result.title, "Title A");
    }

    #[test]
    fn merge_budget_title_no_changes_keeps_mem_title() {
        let mem = make_budget("Keep Me", 1, vec![], empty_changes());
        let disk = make_budget("Disk Title", 2, vec![], empty_changes());
        let result = merge(mem, disk);
        assert_eq!(result.title, "Keep Me");
    }

    #[test]
    fn merge_category_field_newer_timestamp_wins() {
        let cat_id = Uuid::from_u128(0xCA7);

        let mut mem_changes = empty_changes();
        mem_changes.categories.insert(
            cat_id,
            HashMap::from([(
                CategoryField::Title,
                CategoryChange {
                    change_id: Uuid::new_v4(),
                    timestamp: ts(100, 0, DEVICE_A),
                    operation: CRDTOperation::Update,
                    category_id: cat_id,
                    payload: Some(CategoryChangePayload {
                        ordinal: None,
                        title: Some("Old Title".to_string()),
                        amount_planned: None,
                        amount_accumulated: None,
                        category_type: None,
                    }),
                },
            )]),
        );

        let mut disk_changes = empty_changes();
        disk_changes.categories.insert(
            cat_id,
            HashMap::from([(
                CategoryField::Title,
                CategoryChange {
                    change_id: Uuid::new_v4(),
                    timestamp: ts(200, 0, DEVICE_B),
                    operation: CRDTOperation::Update,
                    category_id: cat_id,
                    payload: Some(CategoryChangePayload {
                        ordinal: None,
                        title: Some("New Title".to_string()),
                        amount_planned: None,
                        amount_accumulated: None,
                        category_type: None,
                    }),
                },
            )]),
        );

        let cat = make_category(cat_id, 0, "Original", vec![]);
        let mem = make_budget("B", 1, vec![cat.clone()], mem_changes);
        let disk = make_budget("B", 1, vec![cat], disk_changes);
        let result = merge(mem, disk);

        assert_eq!(result.categories.len(), 1);
        assert_eq!(result.categories[0].title, "New Title");
    }

    #[test]
    fn merge_category_independent_fields_from_both_sides() {
        let cat_id = Uuid::from_u128(0xCA7);

        let mut mem_changes = empty_changes();
        mem_changes.categories.insert(
            cat_id,
            HashMap::from([(
                CategoryField::Title,
                CategoryChange {
                    change_id: Uuid::new_v4(),
                    timestamp: ts(100, 0, DEVICE_A),
                    operation: CRDTOperation::Update,
                    category_id: cat_id,
                    payload: Some(CategoryChangePayload {
                        ordinal: None,
                        title: Some("Mem Title".to_string()),
                        amount_planned: None,
                        amount_accumulated: None,
                        category_type: None,
                    }),
                },
            )]),
        );

        let mut disk_changes = empty_changes();
        disk_changes.categories.insert(
            cat_id,
            HashMap::from([(
                CategoryField::AmountPlanned,
                CategoryChange {
                    change_id: Uuid::new_v4(),
                    timestamp: ts(100, 0, DEVICE_B),
                    operation: CRDTOperation::Update,
                    category_id: cat_id,
                    payload: Some(CategoryChangePayload {
                        ordinal: None,
                        title: None,
                        amount_planned: Some(BWMoneyAmount { value: 50000 }),
                        amount_accumulated: None,
                        category_type: None,
                    }),
                },
            )]),
        );

        let mem = make_budget(
            "B",
            1,
            vec![make_category(cat_id, 0, "Original", vec![])],
            mem_changes,
        );
        let disk = make_budget(
            "B",
            1,
            vec![make_category(cat_id, 0, "Original", vec![])],
            disk_changes,
        );
        let result = merge(mem, disk);

        assert_eq!(result.categories[0].title, "Mem Title");
        assert_eq!(result.categories[0].amount_planned.value, 50000);
    }

    #[test]
    fn merge_transaction_field_newer_wins() {
        let cat_id = Uuid::from_u128(0xCA7);
        let tx_id = Uuid::from_u128(0x7A);

        let mut mem_changes = empty_changes();
        mem_changes.transactions.insert(
            tx_id,
            HashMap::from([(
                TransactionField::Title,
                TransactionChange {
                    change_id: Uuid::new_v4(),
                    timestamp: ts(100, 0, DEVICE_A),
                    operation: CRDTOperation::Update,
                    category_id: cat_id,
                    transaction_id: tx_id,
                    payload: Some(TransactionChangePayload {
                        title: Some("Old Tx".to_string()),
                        description: None,
                        date: None,
                        amount: None,
                    }),
                },
            )]),
        );

        let mut disk_changes = empty_changes();
        disk_changes.transactions.insert(
            tx_id,
            HashMap::from([(
                TransactionField::Title,
                TransactionChange {
                    change_id: Uuid::new_v4(),
                    timestamp: ts(200, 0, DEVICE_B),
                    operation: CRDTOperation::Update,
                    category_id: cat_id,
                    transaction_id: tx_id,
                    payload: Some(TransactionChangePayload {
                        title: Some("New Tx".to_string()),
                        description: None,
                        date: None,
                        amount: None,
                    }),
                },
            )]),
        );

        let tx = make_transaction(tx_id, "Original", 1000);
        let cat = make_category(cat_id, 0, "Cat", vec![tx.clone()]);
        let mem = make_budget("B", 1, vec![cat.clone()], mem_changes);
        let disk = make_budget("B", 1, vec![cat], disk_changes);
        let result = merge(mem, disk);

        assert_eq!(result.categories[0].transactions[0].title, "New Tx");
    }

    #[test]
    fn merge_transaction_category_newer_wins() {
        let first_cat_id = Uuid::from_u128(0xCA71);
        let second_cat_id = Uuid::from_u128(0xCA72);
        let tx_id = Uuid::from_u128(0x7A);

        let mut mem_changes = empty_changes();
        mem_changes.transactions.insert(
            tx_id,
            HashMap::from([(
                TransactionField::Category,
                TransactionChange {
                    change_id: Uuid::new_v4(),
                    timestamp: ts(100, 0, DEVICE_A),
                    operation: CRDTOperation::Update,
                    category_id: first_cat_id,
                    transaction_id: tx_id,
                    payload: None,
                },
            )]),
        );

        let mut disk_changes = empty_changes();
        disk_changes.transactions.insert(
            tx_id,
            HashMap::from([(
                TransactionField::Category,
                TransactionChange {
                    change_id: Uuid::new_v4(),
                    timestamp: ts(200, 0, DEVICE_B),
                    operation: CRDTOperation::Update,
                    category_id: second_cat_id,
                    transaction_id: tx_id,
                    payload: None,
                },
            )]),
        );

        let tx = make_transaction(tx_id, "Moved Tx", 1000);
        let mem = make_budget(
            "B",
            1,
            vec![
                make_category(first_cat_id, 0, "First", vec![tx.clone()]),
                make_category(second_cat_id, 1, "Second", vec![]),
            ],
            mem_changes,
        );
        let disk = make_budget(
            "B",
            1,
            vec![
                make_category(first_cat_id, 0, "First", vec![]),
                make_category(second_cat_id, 1, "Second", vec![tx]),
            ],
            disk_changes,
        );
        let result = merge(mem, disk);

        let first_category = result
            .categories
            .iter()
            .find(|category| category.id == first_cat_id)
            .unwrap();
        let second_category = result
            .categories
            .iter()
            .find(|category| category.id == second_cat_id)
            .unwrap();

        assert!(first_category.transactions.is_empty());
        assert_eq!(second_category.transactions.len(), 1);
        assert_eq!(second_category.transactions[0].id, tx_id);
    }

    #[test]
    fn merge_category_tombstone_excludes_category() {
        let cat_id = Uuid::from_u128(0xCA7);

        let mut disk_changes = empty_changes();
        disk_changes
            .category_tombstones
            .insert(cat_id, ts(100, 0, DEVICE_B));

        let cat = make_category(cat_id, 0, "Deleted", vec![]);
        let mem = make_budget("B", 1, vec![cat.clone()], empty_changes());
        let disk = make_budget("B", 1, vec![cat], disk_changes);
        let result = merge(mem, disk);

        assert!(result.categories.is_empty());
    }

    #[test]
    fn merge_transaction_tombstone_excludes_transaction() {
        let cat_id = Uuid::from_u128(0xCA7);
        let tx_id = Uuid::from_u128(0x7A);

        let mut disk_changes = empty_changes();
        disk_changes
            .transaction_tombstones
            .insert(tx_id, ts(100, 0, DEVICE_B));

        let tx = make_transaction(tx_id, "Deleted Tx", 5000);
        let cat = make_category(cat_id, 0, "Cat", vec![tx.clone()]);
        let mem = make_budget("B", 1, vec![cat.clone()], empty_changes());
        let disk = make_budget("B", 1, vec![cat], disk_changes);
        let result = merge(mem, disk);

        assert_eq!(result.categories[0].transactions.len(), 0);
    }

    #[test]
    fn merge_recalculates_amount_actual() {
        let cat_id = Uuid::from_u128(0xCA7);
        let tx1 = make_transaction(Uuid::from_u128(1), "Tx1", 3000);
        let tx2 = make_transaction(Uuid::from_u128(2), "Tx2", 7000);

        let cat_mem = make_category(cat_id, 0, "Cat", vec![tx1]);
        let cat_disk = make_category(cat_id, 0, "Cat", vec![tx2]);

        let mem = make_budget("B", 1, vec![cat_mem], empty_changes());
        let disk = make_budget("B", 2, vec![cat_disk], empty_changes());
        let result = merge(mem, disk);

        // mem overwrites disk for same tx ids; both should be present
        assert_eq!(result.categories[0].amount_actual.value, 10000);
    }

    #[test]
    fn merge_includes_disk_only_category() {
        let disk_cat_id = Uuid::from_u128(0xD15C);

        let cat_disk = make_category(disk_cat_id, 0, "Disk Only Cat", vec![]);
        let mem = make_budget("B", 1, vec![], empty_changes());
        let disk = make_budget("B", 1, vec![cat_disk], empty_changes());
        let result = merge(mem, disk);

        assert_eq!(result.categories.len(), 1);
        assert_eq!(result.categories[0].title, "Disk Only Cat");
    }

    #[test]
    fn merge_includes_mem_only_category() {
        let mem_cat_id = Uuid::from_u128(0x3E3);

        let cat_mem = make_category(mem_cat_id, 0, "Mem Only Cat", vec![]);
        let mem = make_budget("B", 1, vec![cat_mem], empty_changes());
        let disk = make_budget("B", 1, vec![], empty_changes());
        let result = merge(mem, disk);

        assert_eq!(result.categories.len(), 1);
        assert_eq!(result.categories[0].title, "Mem Only Cat");
    }

    #[test]
    fn merge_categories_sorted_by_ordinal() {
        let cat_a = make_category(Uuid::from_u128(1), 2, "Second", vec![]);
        let cat_b = make_category(Uuid::from_u128(2), 0, "First", vec![]);
        let cat_c = make_category(Uuid::from_u128(3), 1, "Middle", vec![]);

        let mem = make_budget("B", 1, vec![cat_a], empty_changes());
        let disk = make_budget("B", 1, vec![cat_b, cat_c], empty_changes());
        let result = merge(mem, disk);

        let titles: Vec<&str> = result.categories.iter().map(|c| c.title.as_str()).collect();
        assert_eq!(titles, vec!["First", "Middle", "Second"]);
    }

    #[test]
    fn merge_tombstones_keeps_newer() {
        let id = Uuid::from_u128(0xDE);

        let mut mem_changes = empty_changes();
        mem_changes
            .category_tombstones
            .insert(id, ts(100, 0, DEVICE_A));

        let mut disk_changes = empty_changes();
        disk_changes
            .category_tombstones
            .insert(id, ts(200, 0, DEVICE_B));

        let mem = make_budget("B", 1, vec![], mem_changes);
        let disk = make_budget("B", 1, vec![], disk_changes);
        let result = merge(mem, disk);

        assert_eq!(result.changes.category_tombstones[&id].physical_ms, 200);
    }

    #[test]
    fn merge_budget_title_logical_clock_breaks_tie() {
        let mut mem_changes = empty_changes();
        mem_changes.budget.push(BudgetChange {
            change_id: Uuid::new_v4(),
            timestamp: ts(100, 1, DEVICE_A),
            payload: Some(BudgetChangePayload {
                title: Some("Logical Winner".to_string()),
            }),
        });

        let mut disk_changes = empty_changes();
        disk_changes.budget.push(BudgetChange {
            change_id: Uuid::new_v4(),
            timestamp: ts(100, 0, DEVICE_B),
            payload: Some(BudgetChangePayload {
                title: Some("Logical Loser".to_string()),
            }),
        });

        let mem = make_budget("X", 1, vec![], mem_changes);
        let disk = make_budget("X", 1, vec![], disk_changes);
        let result = merge(mem, disk);
        assert_eq!(result.title, "Logical Winner");
    }

    #[test]
    fn merge_mem_category_data_preferred_for_same_id() {
        let cat_id = Uuid::from_u128(0xCA7);
        let cat_mem = make_category(cat_id, 0, "Mem Version", vec![]);
        let cat_disk = make_category(cat_id, 0, "Disk Version", vec![]);

        let mem = make_budget("B", 1, vec![cat_mem], empty_changes());
        let disk = make_budget("B", 1, vec![cat_disk], empty_changes());
        let result = merge(mem, disk);

        // mem is processed second in build_merged_categories, so its base data wins
        assert_eq!(result.categories[0].title, "Mem Version");
    }

    #[test]
    fn merge_preserves_mem_id_and_url() {
        let mem_id = Uuid::from_u128(42);
        let mut mem = make_budget("B", 1, vec![], empty_changes());
        mem.id = mem_id;
        mem.url = Some("/path/to/file".to_string());

        let mut disk = make_budget("B", 1, vec![], empty_changes());
        disk.id = mem_id;
        let result = merge(mem, disk);

        assert_eq!(result.id, mem_id);
        assert_eq!(result.url, Some("/path/to/file".to_string()));
    }
    #[test]
    fn portable_reconciliation_converges_across_orders_and_repeats() {
        let category_id = Uuid::from_u128(10);
        let base = make_budget("Base", 0, vec![make_category(category_id, 0, "Food", vec![])], empty_changes());
        let mut a = normalize_budget_changes(base.clone());
        let mut b = a.clone();
        let mut c = a.clone();
        for (budget, title) in [(&mut a, "Alpha"), (&mut b, "Beta"), (&mut c, "Gamma")] {
            budget.title = title.to_string();
            // Deliberately reuse both timestamp and change ID to exercise payload ties.
            budget.changes.budget[0].payload.as_mut().unwrap().title = Some(title.to_string());
        }
        let merge = |x, y| reconcile_budget_snapshots(x, y).unwrap();
        let ab = merge(a.clone(), b.clone());
        assert!(budget_content_is_equal(&ab, &merge(b.clone(), a.clone())));
        let abc = merge(ab.clone(), c.clone());
        assert!(budget_content_is_equal(&abc, &merge(a.clone(), merge(b, c))));
        assert!(budget_content_is_equal(&abc, &merge(abc.clone(), abc.clone())));
        assert!(budget_content_is_equal(&abc, &merge(abc.clone(), base)));
        assert_eq!(abc.title, "Gamma");
    }

    #[test]
    fn category_deletion_and_concurrent_move_converge() {
        let source = Uuid::from_u128(10);
        let target = Uuid::from_u128(11);
        let tx = make_transaction(Uuid::from_u128(12), "Lunch", 100);
        let base = normalize_budget_changes(make_budget("B", 0, vec![
            make_category(source, 0, "Source", vec![tx.clone()]),
            make_category(target, 1, "Target", vec![]),
        ], empty_changes()));
        let mut deleted = base.clone();
        deleted.categories.remove(0);
        deleted.changes.category_tombstones.insert(source, ts(10, 0, DEVICE_A));
        deleted.changes.transaction_tombstones.insert(tx.id, ts(10, 0, DEVICE_A));
        let mut moved = base.clone();
        moved.categories[0].transactions.clear();
        moved.categories[0].amount_actual.value = 0;
        moved.categories[1].transactions.push(tx.clone());
        moved.categories[1].amount_actual.value = 100;
        let change = moved.changes.transactions.get_mut(&tx.id).unwrap().get_mut(&TransactionField::Category).unwrap();
        change.category_id = target;
        change.timestamp = ts(20, 0, DEVICE_B);
        let merged = reconcile_budget_snapshots(deleted.clone(), moved.clone()).unwrap();
        assert!(merged.categories.iter().all(|c| c.transactions.is_empty()));
        assert!(budget_content_is_equal(&merged, &reconcile_budget_snapshots(moved, deleted).unwrap()));
        assert!(budget_content_is_equal(&merged, &reconcile_budget_snapshots(merged.clone(), base).unwrap()));
    }

    #[test]
    fn reconciliation_rejects_transaction_total_overflow() {
        let category = make_category(Uuid::from_u128(10), 0, "Food", vec![]);
        let mut a = make_budget("B", 0, vec![category.clone()], empty_changes());
        let mut b = a.clone();
        a.categories[0].transactions.push(make_transaction(Uuid::from_u128(20), "A", i64::MAX));
        a.categories[0].amount_actual.value = i64::MAX;
        b.categories[0].transactions.push(make_transaction(Uuid::from_u128(21), "B", 1));
        b.categories[0].amount_actual.value = 1;
        assert!(reconcile_budget_snapshots(a, b).is_err());
    }

}
