/* 
 * Budget Warden
 * Copyright (c) 2026 Lazarov & Co EOOD
 * Author: Nikola Lazarov
 *
 * Licensed under the Source-Available Educational License. 
 * See the LICENSE file in the project root for full terms.
 */

use boltffi::*;
use uuid::Uuid;
use crate::models::*;
use std::collections::HashMap;

#[data]
#[derive(Clone, serde::Serialize, serde::Deserialize)]
pub struct HlcTimestamp {
    physical_ms: u64,
    logical: u32,
    device_id: Uuid,
}

#[data]
#[derive(Clone)]
pub enum HlcOrdering {
    Greater,
    Less,
    Equal,
}

#[data(impl)]
impl HlcTimestamp {
    pub fn compare_with(&self, another_stamp: &HlcTimestamp) -> HlcOrdering {
        if self.physical_ms > another_stamp.physical_ms {
            return HlcOrdering::Greater;
        }

        if self.physical_ms < another_stamp.physical_ms {
            return HlcOrdering::Less;
        }

        if self.logical > another_stamp.logical {
            return HlcOrdering::Greater;
        }

        if self.logical < another_stamp.logical {
            return HlcOrdering::Less;
        }

        HlcOrdering::Equal
    }
}

#[data]
#[derive(Clone)]
pub enum CRDTOperation {
    Create,
    Update,
    Delete,
}

#[data]
pub struct TransactionChangePayload {
    pub title: Option<String>,
    pub description: Option<String>,
    pub date: Option<BWDate>,
    pub amount: Option<BWMoneyAmount>,
}

#[data]
pub struct TransactionChange {
    change_id: Uuid,
    timestamp: HlcTimestamp,
    operation: CRDTOperation,
    category_id: Uuid,
    transaction_id: Uuid,
    payload: Option<TransactionChangePayload>,
}

#[data]
pub struct CategoryChangePayload {
    pub ordinal: Option<i32>,
    pub title: Option<String>,
    pub amount_planned: Option<BWMoneyAmount>,
    pub amount_accumulated: Option<BWMoneyAmount>,
    pub category_type: Option<BWCategoryType>,
}

#[data]
pub struct CategoryChange {
    change_id: Uuid,
    timestamp: HlcTimestamp,
    operation: CRDTOperation,
    category_id: Uuid,
    payload: Option<CategoryChangePayload>,
}

#[data]
pub struct BudgetChangePayload {
    pub title: Option<String>,
}

#[data]
pub struct BudgetChange {
    change_id: Uuid,
    timestamp: HlcTimestamp,
    payload: Option<BudgetChangePayload>,
}

#[data]
#[derive(Clone, Eq, PartialEq, Hash)]
pub enum CategoryField {
    Ordinal,
    Title,
    AmountPlanned,
    AmountAccumulated,
    CategoryType,
}

#[data]
#[derive(Clone, Eq, PartialEq, Hash)]
pub enum TransactionField {
    Title,
    Description,
    Date,
    Amount,
}

#[data]
pub struct CRDTChanges {
    pub budget: Vec<BudgetChange>,
    pub categories: HashMap<Uuid, HashMap<CategoryField, CategoryChange>>,
    pub transactions: HashMap<Uuid, HashMap<TransactionField, TransactionChange>>,
    pub category_tombstones: HashMap<Uuid, HlcTimestamp>,
    pub transaction_tombstones: HashMap<Uuid, HlcTimestamp>,
}

/* 
 Data structure
 changes: {
    budget: {
        update,
    }
    category: {
        uuid: {
            field: { change }
            field: { change }
            field: { change }
        },
        uuid: {
            field: { change }
            field: { change }
            field: { change }
        }
    }
    transactions: { 
        uuid: {
            field: { change }
            field: { change }
            field: { change }
        },
        uuid: {
            field: { change }
            field: { change }
            field: { change }
        }
    }
    transaction_tombstones: {
        { uuid, timestamp }
        { uuid, timestamp }
        { uuid, timestamp }
        { uuid, timestamp }
        { uuid, timestamp }
    },
    category_tombstones: {
        { uuid, timestamp }
        { uuid, timestamp }
        { uuid, timestamp }
        { uuid, timestamp }
        { uuid, timestamp }
        { uuid, timestamp }
        { uuid, timestamp } 
    }
 }
*/

