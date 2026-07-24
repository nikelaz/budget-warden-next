/*
 * Budget Warden
 * Copyright (c) 2026 Lazarov & Co EOOD
 * Author: Nikola Lazarov
 *
 * Licensed under the Source-Available Educational License.
 * See the LICENSE file in the project root for full terms.
 */

use crate::domain::create_category as add_category;
use crate::models::*;
use boltffi::*;
use uuid::Uuid;

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
        BWTemplateType::Empty => BWBudget::new(title),
        BWTemplateType::BasicMonthly => {
            let categories = vec![
                create_category(0, "Salary".to_string(), 480000, BWCategoryType::Income),
                create_category(
                    0,
                    "Fun & Entertainment".to_string(),
                    20000,
                    BWCategoryType::Expenses,
                ),
                create_category(
                    1,
                    "Health & Fitness".to_string(),
                    15000,
                    BWCategoryType::Expenses,
                ),
                create_category(2, "Giving".to_string(), 24000, BWCategoryType::Expenses),
                create_category(3, "Utilities".to_string(), 28000, BWCategoryType::Expenses),
                create_category(
                    4,
                    "Miscellaneous".to_string(),
                    15000,
                    BWCategoryType::Expenses,
                ),
                create_category(5, "Insurance".to_string(), 30000, BWCategoryType::Expenses),
                create_category(6, "Housing".to_string(), 120000, BWCategoryType::Expenses),
                create_category(7, "Food".to_string(), 64000, BWCategoryType::Expenses),
                create_category(
                    8,
                    "Personal Care".to_string(),
                    18000,
                    BWCategoryType::Expenses,
                ),
                create_category(
                    9,
                    "Transportation".to_string(),
                    24000,
                    BWCategoryType::Expenses,
                ),
                create_category(
                    0,
                    "Emergency Fund".to_string(),
                    50000,
                    BWCategoryType::Savings,
                ),
                create_category(1, "Retirement".to_string(), 72000, BWCategoryType::Savings),
            ];

            let mut new_budget = BWBudget::new(title);
            for category in categories {
                new_budget =
                    add_category(new_budget, category).expect("template categories must be valid");
            }
            new_budget
        }
        BWTemplateType::PreviousBudget(budget) => {
            let categories = budget.categories;
            let mut new_budget = BWBudget::new(title);
            for category in categories {
                new_budget =
                    add_category(new_budget, category).expect("template categories must be valid");
            }
            new_budget
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::app_state::initialize_core;
    use crate::domain::update_category;

    fn initialize_test_core() {
        let _ = initialize_core(Uuid::from_u128(0x7E57));
    }

    fn assert_category_changes_are_initialized(budget: &BWBudget) {
        assert_eq!(budget.changes.categories.len(), budget.categories.len());

        for category in &budget.categories {
            let changes = budget
                .changes
                .categories
                .get(&category.id)
                .expect("category must have CRDT changes");
            assert_eq!(changes.len(), 5);
        }
    }

    fn assert_first_category_can_be_updated(mut budget: BWBudget) {
        let category = budget
            .categories
            .first_mut()
            .expect("template must contain a category");
        category.title = "Updated Category".to_string();
        let updated_category = category.clone();

        let updated_budget = update_category(budget, updated_category)
            .expect("template category update must succeed");
        assert_eq!(updated_budget.categories[0].title, "Updated Category");
    }

    #[test]
    fn basic_monthly_initializes_category_changes() {
        initialize_test_core();

        let budget =
            budget_from_template(BWTemplateType::BasicMonthly, "Monthly Budget".to_string());

        assert_category_changes_are_initialized(&budget);
        assert_first_category_can_be_updated(budget);
    }

    #[test]
    fn previous_budget_initializes_category_changes() {
        initialize_test_core();

        let mut previous_budget = BWBudget::new("Previous Budget".to_string());
        previous_budget.categories.push(create_category(
            0,
            "Copied Category".to_string(),
            10000,
            BWCategoryType::Expenses,
        ));

        let budget = budget_from_template(
            BWTemplateType::PreviousBudget(previous_budget),
            "New Budget".to_string(),
        );

        assert_category_changes_are_initialized(&budget);
        assert_first_category_can_be_updated(budget);
    }
}
