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
use crate::validation::validate_budget;
use boltffi::*;
use uuid::Uuid;

#[data]
#[derive(Clone, Copy, PartialEq, Eq)]
pub enum BWTemplateType {
    Empty,
    BasicMonthly,
    WeeklyPersonal,
    FreelancerMonthly,
    SmallBusinessMonthly,
    Vacation,
}

#[data]
#[derive(Clone)]
pub struct BWTemplateCategoryDefinition {
    pub ordinal: i32,
    pub title: String,
    pub amount_planned: BWMoneyAmount,
    pub category_type: BWCategoryType,
}

#[data]
#[derive(Clone)]
pub struct BWTemplateCatalogEntry {
    pub id: String,
    pub template_type: BWTemplateType,
    pub title: String,
    pub family: String,
    pub description: String,
    pub default_reporting_mode: String,
    pub setup_kind: String,
    pub categories: Vec<BWTemplateCategoryDefinition>,
}

fn category(
    ordinal: i32,
    title: &str,
    amount: i64,
    category_type: BWCategoryType,
) -> BWTemplateCategoryDefinition {
    BWTemplateCategoryDefinition {
        ordinal,
        title: title.to_string(),
        amount_planned: BWMoneyAmount { value: amount },
        category_type,
    }
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

fn template_details(template: BWTemplateType) -> BWTemplateCatalogEntry {
    let (id, title, family, description, categories) = match template {
        BWTemplateType::Empty => (
            "empty",
            "Empty Budget",
            "General",
            "Start with no categories.",
            vec![],
        ),
        BWTemplateType::BasicMonthly => (
            "basic-monthly",
            "Monthly Budget",
            "Personal",
            "Answer a few questions about your pay, housing, and goals to plan each month.",
            vec![
                category(0, "Salary", 0, BWCategoryType::Income),
                category(0, "Fun & Entertainment", 0, BWCategoryType::Expenses),
                category(1, "Health & Fitness", 0, BWCategoryType::Expenses),
                category(2, "Giving", 0, BWCategoryType::Expenses),
                category(3, "Utilities", 0, BWCategoryType::Expenses),
                category(4, "Miscellaneous", 0, BWCategoryType::Expenses),
                category(5, "Insurance", 0, BWCategoryType::Expenses),
                category(6, "Housing", 0, BWCategoryType::Expenses),
                category(7, "Food", 0, BWCategoryType::Expenses),
                category(8, "Personal Care", 0, BWCategoryType::Expenses),
                category(9, "Transportation", 0, BWCategoryType::Expenses),
                category(0, "Emergency Fund", 0, BWCategoryType::Savings),
                category(1, "Retirement", 0, BWCategoryType::Savings),
                category(0, "Debt Payments", 0, BWCategoryType::Debt),
            ],
        ),
        BWTemplateType::WeeklyPersonal => (
            "weekly-personal",
            "Weekly Budget",
            "Personal",
            "Answer a few questions about your pay, housing, and goals to plan each week.",
            vec![
                category(0, "Salary", 0, BWCategoryType::Income),
                category(0, "Fun & Entertainment", 0, BWCategoryType::Expenses),
                category(1, "Health & Fitness", 0, BWCategoryType::Expenses),
                category(2, "Giving", 0, BWCategoryType::Expenses),
                category(3, "Utilities", 0, BWCategoryType::Expenses),
                category(4, "Miscellaneous", 0, BWCategoryType::Expenses),
                category(5, "Insurance", 0, BWCategoryType::Expenses),
                category(6, "Housing", 0, BWCategoryType::Expenses),
                category(7, "Food", 0, BWCategoryType::Expenses),
                category(8, "Personal Care", 0, BWCategoryType::Expenses),
                category(9, "Transportation", 0, BWCategoryType::Expenses),
                category(0, "Emergency Fund", 0, BWCategoryType::Savings),
                category(1, "Retirement", 0, BWCategoryType::Savings),
                category(0, "Debt Payments", 0, BWCategoryType::Debt),
            ],
        ),
        BWTemplateType::FreelancerMonthly => (
            "freelancer-monthly",
            "Freelancer Monthly Budget",
            "Business",
            "Pay yourself from client income after business costs, taxes, and a buffer for quieter months.",
            vec![
                category(0, "Client Income", 0, BWCategoryType::Income),
                category(0, "Owner Pay", 0, BWCategoryType::Expenses),
                category(1, "Business Costs", 0, BWCategoryType::Expenses),
                category(0, "Tax Reserve", 0, BWCategoryType::Savings),
                category(1, "Income Buffer", 0, BWCategoryType::Savings),
            ],
        ),
        BWTemplateType::SmallBusinessMonthly => (
            "small-business-monthly",
            "Small Business Monthly Budget",
            "Business",
            "Plan monthly cash across sales, the main costs, taxes, owner pay, and a reserve.",
            vec![
                category(0, "Sales", 0, BWCategoryType::Income),
                category(0, "Inventory & Materials", 0, BWCategoryType::Expenses),
                category(1, "Payroll & Benefits", 0, BWCategoryType::Expenses),
                category(2, "Rent & Utilities", 0, BWCategoryType::Expenses),
                category(3, "Operating Costs", 0, BWCategoryType::Expenses),
                category(4, "Owner Pay", 0, BWCategoryType::Expenses),
                category(0, "Tax Reserve", 0, BWCategoryType::Savings),
                category(1, "Operating Reserve", 0, BWCategoryType::Savings),
            ],
        ),
        BWTemplateType::Vacation => (
            "vacation",
            "Trip Budget",
            "Travel",
            "Plan tickets, where you stay, a daily allowance for everything else, and a buffer for surprises.",
            vec![
                category(0, "Travel Budget", 0, BWCategoryType::Income),
                category(0, "Getting There", 0, BWCategoryType::Expenses),
                category(1, "Accommodation", 0, BWCategoryType::Expenses),
                category(2, "Per Diem", 0, BWCategoryType::Expenses),
                category(3, "Activities & Extras", 0, BWCategoryType::Expenses),
                category(0, "Emergency Buffer", 0, BWCategoryType::Savings),
            ],
        ),
    };

    BWTemplateCatalogEntry {
        id: id.to_string(),
        template_type: template,
        title: title.to_string(),
        family: family.to_string(),
        description: description.to_string(),
        default_reporting_mode: "income-allocation".to_string(),
        setup_kind: if template == BWTemplateType::Empty { "none" } else { "questions" }.to_string(),
        categories,
    }
}

#[export]
pub fn template_catalog() -> Vec<BWTemplateCatalogEntry> {
    [
        BWTemplateType::BasicMonthly,
        BWTemplateType::WeeklyPersonal,
        BWTemplateType::FreelancerMonthly,
        BWTemplateType::SmallBusinessMonthly,
        BWTemplateType::Vacation,
        BWTemplateType::Empty,
    ]
    .into_iter()
    .map(template_details)
    .collect()
}

#[export]
pub fn budget_from_template_id(template_id: String, title: String) -> Result<BWBudget, String> {
    let template = template_catalog()
        .into_iter()
        .find(|template| template.id == template_id)
        .map(|template| template.template_type)
        .ok_or_else(|| format!("Unknown budget template ID '{template_id}'."))?;
    Ok(budget_from_template(template, title))
}

#[export]
pub fn budget_from_template(template: BWTemplateType, title: String) -> BWBudget {
    budget_from_definitions(title, template_details(template).categories)
        .expect("built-in template categories must be valid")
}

/// Builds a fresh budget whose categories have new IDs and initialized
/// change history.
pub(crate) fn budget_from_definitions(
    title: String,
    definitions: Vec<BWTemplateCategoryDefinition>,
) -> Result<BWBudget, String> {
    let mut new_budget = BWBudget::new(title);
    for definition in definitions {
        let template_category = create_category(
            definition.ordinal,
            definition.title,
            definition.amount_planned.value,
            definition.category_type,
        );
        new_budget = add_category(new_budget, template_category)?;
    }
    Ok(new_budget)
}

#[export]
pub fn budget_from_previous_budget(budget: BWBudget, title: String) -> Result<BWBudget, String> {
    validate_budget(&budget)?;

    let categories = budget.categories;
    let currency = budget.currency;
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
    if let Some(currency) = currency {
        new_budget = crate::domain::update_budget_currency(new_budget, currency)?;
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

    #[test]
    fn catalog_templates_create_valid_budgets_with_ordered_categories() {
        initialize_test_core();
        for entry in template_catalog() {
            let budget = budget_from_template(entry.template_type, entry.title);
            validate_budget(&budget).unwrap();
            for category_type in [
                BWCategoryType::Income,
                BWCategoryType::Expenses,
                BWCategoryType::Savings,
                BWCategoryType::Debt,
            ] {
                let categories: Vec<_> = entry
                    .categories
                    .iter()
                    .filter(|category| category.category_type == category_type)
                    .collect();
                for (ordinal, category) in categories.iter().enumerate() {
                    assert_eq!(category.ordinal, ordinal as i32);
                    assert_eq!(
                        categories
                            .iter()
                            .filter(|other| other.title == category.title)
                            .count(),
                        1
                    );
                }
            }
        }
    }

    #[test]
    fn travel_templates_include_funding_without_assuming_an_amount() {
        for template in [BWTemplateType::Vacation] {
            let entry = template_details(template);
            let income: Vec<_> = entry
                .categories
                .iter()
                .filter(|category| category.category_type == BWCategoryType::Income)
                .collect();
            assert_eq!(income.len(), 1);
            assert_eq!(income[0].title, "Travel Budget");
            assert!(
                entry
                    .categories
                    .iter()
                    .all(|category| category.amount_planned.value == 0)
            );
        }
    }

    #[test]
    fn catalog_lists_personal_templates_first_and_empty_last() {
        let ids: Vec<_> = template_catalog().into_iter().map(|entry| entry.id).collect();
        assert_eq!(&ids[..2], ["basic-monthly", "weekly-personal"]);
        assert_eq!(ids.last().map(String::as_str), Some("empty"));
    }

    #[test]
    fn templates_start_at_zero_until_setup_answers_are_given() {
        for entry in template_catalog() {
            assert!(
                entry.categories.iter().all(|category| category.amount_planned.value == 0),
                "{} has prefilled amounts",
                entry.id
            );
            assert_eq!(entry.setup_kind == "questions", entry.template_type != BWTemplateType::Empty);
        }
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

        let budget =
            budget_from_previous_budget(previous_budget, "New Budget".to_string()).unwrap();

        assert_category_changes_are_initialized(&budget);
        assert_eq!(budget.categories.len(), 1);
        assert_ne!(budget.categories[0].id, previous_category_id);
        assert_eq!(budget.categories[0].amount_planned.value, 10000);
        assert_eq!(budget.categories[0].amount_actual.value, 0);
        assert!(budget.categories[0].transactions.is_empty());
        assert!(budget.changes.transactions.is_empty());
        assert_first_category_can_be_updated(budget);
    }

    #[test]
    fn previous_budget_currency_is_copied() {
        initialize_test_core();
        let previous = crate::domain::update_budget_currency(
            BWBudget::new("October".to_string()),
            "EUR".to_string(),
        )
        .unwrap();

        let budget = budget_from_previous_budget(previous, "November".to_string()).unwrap();
        assert_eq!(budget.currency.as_deref(), Some("EUR"));

        let without =
            budget_from_previous_budget(BWBudget::new("Old".to_string()), "New".to_string())
                .unwrap();
        assert!(without.currency.is_none());
    }
}
