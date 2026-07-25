/* 
 * Budget Warden
 * Copyright (c) 2026 Lazarov & Co EOOD
 * Author: Nikola Lazarov
 *
 * Licensed under the Source-Available Educational License. 
 * See the LICENSE file in the project root for full terms.
 */

use std::collections::HashMap;

use boltffi::*;
use serde::{Serialize, Deserialize};
use uuid::Uuid;
use chrono::{Datelike, Local};
use crate::crdt::*;
use crate::validation::{checked_money_sum, validate_money_amount};

pub(crate) const CURRENT_SCHEMA_VERSION: i32 = 2;

fn always_skip_migration_writeback(_: &bool) -> bool {
    true
}

#[data]
#[derive(Clone, Serialize, Deserialize)]
pub struct BWBudget {
    pub id: Uuid,
    pub revision: i64,
    pub revision_id: Uuid,
    pub schema_version: i32,
    pub title: String,
    pub categories: Vec<BWCategory>,
    pub changes: CRDTChanges, 

    #[serde(skip_serializing)]
    pub url: Option<String>,

    #[serde(default, skip_serializing_if = "always_skip_migration_writeback")]
    pub requires_migration_writeback: bool,
}

#[data(impl)]
impl BWBudget {
    pub fn new(title: String) -> Self {
        BWBudget {
            id: Uuid::new_v4(),
            revision: 0,
            revision_id: Uuid::new_v4(),
            schema_version: CURRENT_SCHEMA_VERSION,
            title,
            categories: vec![],
            changes: CRDTChanges {
                budget: vec![],
                categories: HashMap::new(),
                transactions: HashMap::new(),
                category_tombstones: HashMap::new(),
                transaction_tombstones: HashMap::new(),
            },
            url: None,
            requires_migration_writeback: false,
        }
    }

    pub fn update_actuals(&self) -> Result<BWBudget, String> {
        let mut budget = self.clone();

        for category in &mut budget.categories {
            category.update_actuals()?;
        }

        Ok(budget)
    }

    pub fn ordered_categories(&self, category_type: Option<BWCategoryType>) -> Vec<BWCategory> {
        let mut categories: Vec<_> = self.categories
            .iter()
            .filter(|category| {
                category_type.is_none_or(|value| category.category_type == value)
            })
            .cloned()
            .collect();

        categories.sort_by_key(|category| (category.category_type as i32, category.ordinal));
        categories
    }
}

#[data]
#[derive(Clone, Serialize, Deserialize)]
pub struct BWCategory {
    pub id: Uuid,
    pub ordinal: i32,
    pub title: String,
    pub amount_planned: BWMoneyAmount,
    pub amount_actual: BWMoneyAmount,
    pub amount_accumulated: BWMoneyAmount,
    pub category_type: BWCategoryType,
    pub transactions: Vec<BWTransaction>
}

impl BWCategory {
    pub fn update_actuals(&mut self) -> Result<(), String> {
        self.amount_actual = checked_money_sum(
            self.transactions.iter().map(|transaction| transaction.amount),
            &format!("Category {} actual amount", self.id),
        )?;
        Ok(())
    }
}

#[data]
#[derive(Clone, Serialize, Deserialize)]
pub struct BWTransaction {
    pub id: Uuid,
    pub title: String,
    pub description: String,
    pub date: BWDate, 
    pub amount: BWMoneyAmount,
}

#[export]
pub fn new_transaction(
    title: String,
    description: Option<String>,
    date: Option<BWDate>,
    amount: BWMoneyAmount,
) -> Result<BWTransaction, String> {
    validate_money_amount(amount, "Transaction amount")?;
    Ok(BWTransaction {
        id: Uuid::new_v4(),
        title,
        description: description.unwrap_or_default(),
        date: date.unwrap_or(BWDate::now()),
        amount,
    })
}

#[data]
#[derive(Clone, Copy, Serialize, Deserialize, PartialEq, Debug)]
#[serde(rename_all = "lowercase")]
pub enum BWCategoryType {
    Income = 1,
    Expenses = 2,
    Savings = 3,
    Debt = 4,
}

#[data(impl)]
impl BWCategoryType {
    pub fn to_string(&self) -> String {
        match self {
            BWCategoryType::Income => "Income",
            BWCategoryType::Expenses => "Expenses",
            BWCategoryType::Savings => "Savings",
            BWCategoryType::Debt => "Debt",
        }.to_string()
    }
}

#[data]
#[derive(Copy, Clone, Serialize, Deserialize, PartialEq, Eq, PartialOrd, Ord)]
pub struct BWDate {
    pub year: i32,
    pub month: i32,
    pub day: i32,
}

#[data(impl)]
impl BWDate {
    pub fn now() -> BWDate {
        let today = Local::now().date_naive();
        Self {
             year: today.year(),
             month: today.month() as i32,
             day: today.day() as i32,
        }
    }
}

#[data]
#[derive(Copy, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(transparent)]
pub struct BWMoneyAmount {
    pub value: i64,
}
