/* 
 * Budget Warden
 * Copyright (c) 2026 Lazarov & Co EOOD
 * Author: Nikola Lazarov
 *
 * Licensed under the Source-Available Educational License. 
 * See the LICENSE file in the project root for full terms.
 */

use boltffi::*;
use serde::{Serialize, Deserialize};
use uuid::Uuid;
use chrono::{Datelike, Local};

#[data]
#[derive(Serialize, Deserialize)]
pub struct BWBudget {
    pub id: Uuid,
    pub revision: i64,
    pub revision_id: Uuid,
    pub schema_version: i32,
    pub title: String,
    pub categories: Vec<BWCategory>,
}

#[data]
#[derive(Serialize, Deserialize)]
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

#[data]
#[derive(Serialize, Deserialize)]
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

#[data]
#[derive(Copy, Clone, Serialize, Deserialize)]
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
#[derive(Copy, Clone, Serialize, Deserialize)]
#[serde(transparent)]
pub struct BWMoneyAmount {
    pub value: i64,
}
