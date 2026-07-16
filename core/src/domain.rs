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
pub fn delete_transaction(
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

#[export]
pub fn move_transaction(
    mut budget: BWBudget,
    origin_category_id: Uuid,
    target_category_id: Uuid,
    transaction_id: Uuid,
) -> Result<BWBudget, String> {
    let origin_category_index = budget.categories
        .iter()
        .position(|category| category.id == origin_category_id)
        .ok_or_else(|| {
            format!("Could not find category with id: {origin_category_id} in this budget")
        })?;

    let target_category_index = budget.categories
        .iter()
        .position(|category| category.id == target_category_id)
        .ok_or_else(|| {
            format!("Could not find category with id: {target_category_id} in this budget")
        })?;

    let transaction_index = budget.categories[origin_category_index]
        .transactions
        .iter()
        .position(|transaction| transaction.id == transaction_id)
        .ok_or_else(|| {
            format!("Could not find transaction with id {transaction_id} in this budget")
        })?;

    if origin_category_index == target_category_index {
        return Ok(budget);
    }

    let transaction = budget.categories[origin_category_index]
        .transactions[transaction_index]
        .clone();
    let change = new_change_transaction_update(
        target_category_id,
        transaction,
        TransactionField::Category,
    );
    let transaction_changes = budget.changes.transactions
        .get_mut(&transaction_id)
        .ok_or_else(|| {
            format!("Could not move transaction, crdt changes in the file are corrupted.")
        })?;

    transaction_changes.insert(TransactionField::Category, change);

    let transaction = budget.categories[origin_category_index]
        .transactions
        .remove(transaction_index);
    budget.categories[target_category_index]
        .transactions
        .push(transaction);

    Ok(budget)
}

#[export]
pub fn create_category(
    mut budget: BWBudget,
    category: BWCategory
) -> Result<BWBudget, String> {
    budget.categories.push(category.clone());

    let change = new_change_category_create(category.clone());

    budget.changes.categories.insert(category.id, change);

    Ok(budget)
}

fn ordered_category_ids(
    categories: &[BWCategory],
    category_type: BWCategoryType,
) -> Vec<Uuid> {
    let mut categories_of_type: Vec<(usize, &BWCategory)> = categories
        .iter()
        .enumerate()
        .filter(|(_, category)| category.category_type == category_type)
        .collect();

    categories_of_type.sort_by_key(|(index, category)| (category.ordinal, *index));
    categories_of_type
        .into_iter()
        .map(|(_, category)| category.id)
        .collect()
}

fn update_category_ordinals(
    categories: &mut [BWCategory],
    ordered_category_ids: &[Uuid],
) {
    for (ordinal, category_id) in ordered_category_ids.iter().enumerate() {
        if let Some(category) = categories
            .iter_mut()
            .find(|category| category.id == *category_id)
        {
            category.ordinal = ordinal as i32;
        }
    }
}

fn sort_categories(categories: &mut [BWCategory]) {
    categories.sort_by_key(|category| (
        category.category_type as i32,
        category.ordinal,
    ));
}

#[export]
pub fn update_category(
    mut budget: BWBudget,
    category: BWCategory
) -> Result<BWBudget, String> {
    let original_category = budget.categories
        .iter()
        .find(|item| item.id == category.id)
        .cloned()
        .ok_or_else(|| {
            format!("Could not find category with id: {} in this budget", category.id)
        })?;

    let original_categories = budget.categories.clone();
    let mut updated_categories = budget.categories.clone();
    let category_in_budget = updated_categories
        .iter_mut()
        .find(|x| x.id == category.id)
        .ok_or_else(|| {
            format!("Could not find category with id: {} in this budget", category.id)
        })?;

    category_in_budget.title = category.title;
    category_in_budget.amount_planned = category.amount_planned;
    category_in_budget.amount_accumulated = category.amount_accumulated;
    category_in_budget.category_type = category.category_type;

    if original_category.category_type == category.category_type {
        if original_category.ordinal != category.ordinal {
            let mut ordered_ids = ordered_category_ids(
                &updated_categories,
                category.category_type,
            );
            let target_index = usize::try_from(category.ordinal)
                .ok()
                .filter(|index| *index < ordered_ids.len())
                .ok_or_else(|| {
                    format!("Could not move category to invalid ordinal: {}", category.ordinal)
                })?;
            let current_index = ordered_ids
                .iter()
                .position(|category_id| *category_id == category.id)
                .ok_or_else(|| {
                    format!("Could not find category with id: {} in this budget", category.id)
                })?;

            let moved_category_id = ordered_ids.remove(current_index);
            ordered_ids.insert(target_index, moved_category_id);
            update_category_ordinals(&mut updated_categories, &ordered_ids);
        }
    } else {
        let old_type_ids = ordered_category_ids(
            &updated_categories,
            original_category.category_type,
        );
        update_category_ordinals(&mut updated_categories, &old_type_ids);

        let mut new_type_ids = ordered_category_ids(
            &updated_categories,
            category.category_type,
        );
        new_type_ids.retain(|category_id| *category_id != category.id);
        new_type_ids.push(category.id);
        update_category_ordinals(&mut updated_categories, &new_type_ids);
    }

    sort_categories(&mut updated_categories);

    let mut category_changes = Vec::new();

    for updated_category in &updated_categories {
        let original = original_categories
            .iter()
            .find(|category| category.id == updated_category.id)
            .ok_or_else(|| {
                format!("Could not find category with id: {} in this budget", updated_category.id)
            })?;
        let mut fields = Vec::new();

        if original.ordinal != updated_category.ordinal {
            fields.push(CategoryField::Ordinal);
        }
        if original.title != updated_category.title {
            fields.push(CategoryField::Title);
        }
        if original.amount_planned != updated_category.amount_planned {
            fields.push(CategoryField::AmountPlanned);
        }
        if original.amount_accumulated != updated_category.amount_accumulated {
            fields.push(CategoryField::AmountAccumulated);
        }
        if original.category_type != updated_category.category_type {
            fields.push(CategoryField::CategoryType);
        }

        if !fields.is_empty() {
            category_changes.push((updated_category.id, fields));
        }
    }

    if category_changes.iter().any(|(category_id, _)| {
        !budget.changes.categories.contains_key(category_id)
    }) {
        return Err(format!(
            "Could not update category, crdt changes in the file are corrupted."
        ));
    }

    budget.categories = updated_categories;

    for (category_id, fields) in category_changes {
        let updated_category = budget.categories
            .iter()
            .find(|category| category.id == category_id)
            .cloned()
            .ok_or_else(|| {
                format!("Could not find category with id: {category_id} in this budget")
            })?;
        let changes = budget.changes.categories
            .get_mut(&category_id)
            .ok_or_else(|| {
                format!("Could not update category, crdt changes in the file are corrupted.")
            })?;

        for field in fields {
            let change = new_change_category_update(
                updated_category.clone(),
                field.clone(),
            );
            changes.insert(field, change);
        }
    }

    Ok(budget)
}

#[export]
pub fn delete_category(
    mut budget: BWBudget,
    category_id: Uuid
) -> Result<BWBudget, String> {
    let deleted_category = budget.categories
        .iter()
        .find(|category| category.id == category_id)
        .cloned()
        .ok_or_else(|| {
            format!("Could not find category with id: {category_id} in this budget")
        })?;
    let original_categories = budget.categories.clone();
    let mut remaining_categories = budget.categories.clone();
    let category_index = remaining_categories
        .iter()
        .position(|category| category.id == category_id)
        .ok_or_else(|| {
            format!("Could not find category with id: {category_id} in this budget")
        })?;

    remaining_categories.remove(category_index);

    let ordered_ids = ordered_category_ids(
        &remaining_categories,
        deleted_category.category_type,
    );
    update_category_ordinals(&mut remaining_categories, &ordered_ids);
    sort_categories(&mut remaining_categories);

    let changed_category_ids: Vec<Uuid> = remaining_categories
        .iter()
        .filter_map(|category| {
            original_categories
                .iter()
                .find(|existing| existing.id == category.id)
                .filter(|existing| existing.ordinal != category.ordinal)
                .map(|_| category.id)
        })
        .collect();

    if changed_category_ids.iter().any(|changed_category_id| {
        !budget.changes.categories.contains_key(changed_category_id)
    }) {
        return Err(format!(
            "Could not delete category, crdt changes in the file are corrupted."
        ));
    }

    budget.categories = remaining_categories;

    for changed_category_id in changed_category_ids {
        let changed_category = budget.categories
            .iter()
            .find(|category| category.id == changed_category_id)
            .cloned()
            .ok_or_else(|| {
                format!("Could not find category with id: {changed_category_id} in this budget")
            })?;
        let change = new_change_category_update(
            changed_category,
            CategoryField::Ordinal,
        );
        let category_changes = budget.changes.categories
            .get_mut(&changed_category_id)
            .ok_or_else(|| {
                format!("Could not delete category, crdt changes in the file are corrupted.")
            })?;

        category_changes.insert(CategoryField::Ordinal, change);
    }

    budget.changes.category_tombstones
        .insert(category_id, HlcTimestamp::now());

    Ok(budget)
}
