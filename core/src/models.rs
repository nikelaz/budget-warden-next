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

const CURRENT_SCHEMA_VERSION: i32 = 2;

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
        }
    }

    pub fn update_actuals(&mut self) {
        for category in &mut self.categories {
            category.update_actuals();
        }
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
    pub fn update_actuals(&mut self) {
        let mut actual = 0;

        for transaction in &self.transactions {
            actual += transaction.amount.value;
        }

        self.amount_actual = BWMoneyAmount { value: actual };
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

#[data(impl)]
impl BWTransaction {
    pub fn new(
        title:String,
        description: Option<String>,
        date: Option<BWDate>,
        amount: BWMoneyAmount
    ) -> BWTransaction {
        BWTransaction {
            id: Uuid::new_v4(),
            title: title, 
            description: description.unwrap_or("".to_string()),
            date: date.unwrap_or(BWDate::now()),
            amount: amount,
        }
    }
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
