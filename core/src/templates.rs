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

#[data]
pub enum BWTemplateType {
    Empty,
    BasicMonthly,
    PreviousBudget(BWBudget),
}

fn create_category(
    ordinal: i32,
    title: String,
    amount: i64,
    category_type: BWCategoryType,
) -> BWCategory {
    BWCategory {
        id: Uuid::new_v4(),
        ordinal,
        title,
        amount_planned: BWMoneyAmount { value: amount },
        amount_actual: BWMoneyAmount { value: 0 },
        amount_accumulated: BWMoneyAmount { value: 0 },
        category_type,
        transactions: vec![],
    }
}

#[export]
pub fn budget_from_template(template: BWTemplateType, title: String) -> BWBudget {
    match template {
        BWTemplateType::Empty => {
            BWBudget::new(title)
        },
        BWTemplateType::BasicMonthly => {
            let mut new_budget = BWBudget::new(title);
            new_budget.categories = vec![
                create_category(0, "Salary".to_string(), 480000, BWCategoryType::Income),

                create_category(0, "Fun & Entertainment".to_string(), 20000, BWCategoryType::Expenses),
                create_category(1, "Health & Fitness".to_string(), 15000, BWCategoryType::Expenses),
                create_category(2, "Giving".to_string(), 24000, BWCategoryType::Expenses),
                create_category(3, "Utilities".to_string(), 28000, BWCategoryType::Expenses),
                create_category(4, "Miscellaneous".to_string(), 15000, BWCategoryType::Expenses),
                create_category(5, "Insurance".to_string(), 30000, BWCategoryType::Expenses),
                create_category(6, "Housing".to_string(), 120000, BWCategoryType::Expenses),
                create_category(7, "Food".to_string(), 64000, BWCategoryType::Expenses),
                create_category(8, "Personal Care".to_string(), 18000, BWCategoryType::Expenses),
                create_category(9, "Transportation".to_string(), 24000, BWCategoryType::Expenses),

                create_category(0, "Emergency Fund".to_string(), 50000, BWCategoryType::Savings),
                create_category(1, "Retirement".to_string(), 72000, BWCategoryType::Savings)
            ];
            new_budget
        },
        BWTemplateType::PreviousBudget(budget) => {
            let mut new_budget = BWBudget::new(title);
            new_budget.categories = budget.categories;
            new_budget
        },
    }
}
