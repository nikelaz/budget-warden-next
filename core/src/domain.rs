/* 
 * Budget Warden
 * Copyright (c) 2026 Lazarov & Co EOOD
 * Author: Nikola Lazarov
 *
 * Licensed under the Source-Available Educational License. 
 * See the LICENSE file in the project root for full terms.
 */

use std::fs;
use boltffi::*;
use uuid::Uuid;
use crate::models::*;
use crate::codec;
use crate::crdt;
use crate::crdt::*;
use crate::filesystem;

#[export]
pub fn load_budget(path: String) -> Result<BWBudget, String> {
    let json = fs::read_to_string(&path)
        .map_err(|err| format!("Failed to read budget file: {err}"))?;

    let mut budget = codec::decode_budget(&json)
        .map_err(|err| format!("Failed to decode budget file: {err}"))?;

    budget.url = Some(path);

    Ok(budget)
}

#[export]
pub fn update_and_merge_budget(budget: BWBudget) -> Result<BWBudget, String> {
    let Some(url) = budget.url.clone() else {
        return Err(format!("Budget does not have a URL"));
    };

    let budget_on_disk = load_budget(url.clone())?;

    let mut merged_budget = crdt::merge(budget, budget_on_disk);

    merged_budget.update_actuals();

    let merged_budget_encoded = codec::encode_budget(&merged_budget)?;

    filesystem::write_file_atomic(url.as_str(), merged_budget_encoded.as_bytes())
        .map_err(|_| format!("Could not save the file"))?;

    Ok(merged_budget)
}

#[export]
pub fn delete_budget(path: String) -> Result<(), String> {
    fs::remove_file(&path)
        .map_err(|err| format!("Failed to delete file: {err}"))?;

    Ok(())
}

#[export]
pub fn create_transaction(
    mut budget: BWBudget,
    category_id: Uuid,
    transaction: BWTransaction
) -> Result<BWBudget, String> {
    let category = budget.categories
        .iter_mut()
        .find(|x| x.id == category_id)
        .ok_or_else(|| {
            format!("Could not find category with id: {category_id} in this budget")
        })?;

    category.transactions.push(transaction.clone());
    
    let change = new_change_transaction_create(category_id, transaction.clone()); 

    budget.changes.transactions.insert(transaction.id, change);

    Ok(budget)
}

#[export]
pub fn update_transaction(
    mut budget: BWBudget,
    category_id: Uuid,
    transaction: BWTransaction
) -> Result<BWBudget, String> {
    let category = budget.categories
        .iter_mut()
        .find(|x| x.id == category_id)
        .ok_or_else(|| {
            format!("Could not find category with id: {category_id} in this budget")
        })?;

    let transaction_in_budget = category.transactions
        .iter_mut()
        .find(|x| x.id == transaction.id)
        .ok_or_else(|| {
            format!("Could not find the transaction in budget")
        })?;

    if transaction_in_budget.title != transaction.title {
        transaction_in_budget.title = transaction.title.clone();
        let change = new_change_transaction_update(category_id, transaction.clone(), TransactionField::Title);
        let transaction_changes = budget.changes.transactions.get_mut(&transaction.id);

        let transaction_changes = transaction_changes
            .ok_or_else(|| {
                format!("Could not update transaction, crdt changes in the file are corrupted.")
            })?;

        transaction_changes.insert(TransactionField::Title, change);
    }

    if transaction_in_budget.description != transaction.description {
        transaction_in_budget.description = transaction.description.clone();
        let change = new_change_transaction_update(category_id, transaction.clone(), TransactionField::Description);
        let transaction_changes = budget.changes.transactions.get_mut(&transaction.id);

        let transaction_changes = transaction_changes
            .ok_or_else(|| {
                format!("Could not update transaction, crdt changes in the file are corrupted.")
            })?;

        transaction_changes.insert(TransactionField::Description, change);
    }

    if transaction_in_budget.date != transaction.date {
        transaction_in_budget.date = transaction.date.clone();
        let change = new_change_transaction_update(category_id, transaction.clone(), TransactionField::Date);
        let transaction_changes = budget.changes.transactions.get_mut(&transaction.id);

        let transaction_changes = transaction_changes
            .ok_or_else(|| {
                format!("Could not update transaction, crdt changes in the file are corrupted.")
            })?;

        transaction_changes.insert(TransactionField::Date, change);
    }

    if transaction_in_budget.amount != transaction.amount {
        transaction_in_budget.amount = transaction.amount.clone();
        let change = new_change_transaction_update(category_id, transaction.clone(), TransactionField::Amount);
        let transaction_changes = budget.changes.transactions.get_mut(&transaction.id);

        let transaction_changes = transaction_changes
            .ok_or_else(|| {
                format!("Could not update transaction, crdt changes in the file are corrupted.")
            })?;

        transaction_changes.insert(TransactionField::Amount, change);
    }

    Ok(budget)
}

#[export]
pub fn remove_transaction(
    mut budget: BWBudget,
    category_id: Uuid,
    transaction_id: Uuid
) -> Result<BWBudget, String> {
    let category = budget.categories
        .iter_mut()
        .find(|x| x.id == category_id)
        .ok_or_else(|| {
            format!("Could not find category with id: {category_id} in this budget")
        })?;

    let position = category.transactions
        .iter()
        .position(|x| x.id == transaction_id)
        .ok_or_else(|| {
            format!("Could not find transaction with id {transaction_id} in this budget")
        })?;

    category.transactions.remove(position);

    budget.changes.transaction_tombstones.insert(transaction_id, HlcTimestamp::now());

    Ok(budget)
}
