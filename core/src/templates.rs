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
use crate::validation::validate_budget;

#[data]
#[derive(Clone, Copy, PartialEq, Eq)]
pub enum BWTemplateType {
    Empty,
    BasicMonthly,
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
    }
}

#[export]
pub fn budget_from_previous_budget(
    budget: BWBudget,
    title: String,
) -> Result<BWBudget, String> {
    validate_budget(&budget)?;

    let categories = budget.categories;
    let mut new_budget = BWBudget::new(title);
    for category in categories {
        let template_category = BWCategory {
            id: Uuid::new_v4(),
            ordinal: category.ordinal,
            title: category.title,
            amount_planned: category.amount_planned,
            amount_actual: BWMoneyAmount { value: 0 },
            amount_accumulated: category.amount_accumulated,
            category_type: category.category_type,
            transactions: vec![],
        };
        new_budget = add_category(new_budget, template_category)?;
    }

    validate_budget(&new_budget)?;
    Ok(new_budget)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::app_state::initialize_core;
    use crate::domain::{create_transaction, update_category};

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

        let previous_category = create_category(
            0,
            "Copied Category".to_string(),
            10000,
            BWCategoryType::Expenses,
        );
        let previous_category_id = previous_category.id;
        let previous_budget = add_category(
            BWBudget::new("Previous Budget".to_string()),
            previous_category,
        )
        .unwrap();
        let previous_budget = create_transaction(
            previous_budget,
            previous_category_id,
            new_transaction(
                "Previous transaction".to_string(),
                None,
                None,
                BWMoneyAmount { value: 2500 },
            )
            .unwrap(),
        )
        .unwrap()
        .update_actuals()
        .unwrap();

        let budget = budget_from_previous_budget(
            previous_budget,
            "New Budget".to_string(),
        )
        .unwrap();

        assert_category_changes_are_initialized(&budget);
        assert_eq!(budget.categories.len(), 1);
        assert_ne!(budget.categories[0].id, previous_category_id);
        assert_eq!(budget.categories[0].amount_planned.value, 10000);
        assert_eq!(budget.categories[0].amount_actual.value, 0);
        assert!(budget.categories[0].transactions.is_empty());
        assert!(budget.changes.transactions.is_empty());
        assert_first_category_can_be_updated(budget);
    }
}
