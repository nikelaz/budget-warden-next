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
    BiweeklyPaycheck,
    FreelancerMonthly,
    SmallBusinessMonthly,
    EventPlanning,
    Vacation,
    BusinessTrip,
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
            "Common monthly income, expense, and savings categories.",
            vec![
                category(0, "Salary", 480000, BWCategoryType::Income),
                category(0, "Fun & Entertainment", 20000, BWCategoryType::Expenses),
                category(1, "Health & Fitness", 15000, BWCategoryType::Expenses),
                category(2, "Giving", 24000, BWCategoryType::Expenses),
                category(3, "Utilities", 28000, BWCategoryType::Expenses),
                category(4, "Miscellaneous", 15000, BWCategoryType::Expenses),
                category(5, "Insurance", 30000, BWCategoryType::Expenses),
                category(6, "Housing", 120000, BWCategoryType::Expenses),
                category(7, "Food", 64000, BWCategoryType::Expenses),
                category(8, "Personal Care", 18000, BWCategoryType::Expenses),
                category(9, "Transportation", 24000, BWCategoryType::Expenses),
                category(0, "Emergency Fund", 50000, BWCategoryType::Savings),
                category(1, "Retirement", 72000, BWCategoryType::Savings),
            ],
        ),
        BWTemplateType::WeeklyPersonal => (
            "weekly-personal",
            "Weekly Personal",
            "Personal",
            "Plan weekly essentials, set aside money for upcoming bills, and build savings.",
            vec![
                category(0, "Weekly Income", 0, BWCategoryType::Income),
                category(1, "Other Income", 0, BWCategoryType::Income),
                category(0, "Housing & Utilities", 0, BWCategoryType::Expenses),
                category(1, "Groceries", 0, BWCategoryType::Expenses),
                category(2, "Dining Out", 0, BWCategoryType::Expenses),
                category(3, "Transportation", 0, BWCategoryType::Expenses),
                category(4, "Health & Personal Care", 0, BWCategoryType::Expenses),
                category(5, "Family & Household", 0, BWCategoryType::Expenses),
                category(6, "Fun & Entertainment", 0, BWCategoryType::Expenses),
                category(7, "Giving", 0, BWCategoryType::Expenses),
                category(8, "Miscellaneous", 0, BWCategoryType::Expenses),
                category(0, "Emergency Fund", 0, BWCategoryType::Savings),
                category(
                    1,
                    "Upcoming Bills & Annual Expenses",
                    0,
                    BWCategoryType::Savings,
                ),
                category(2, "Savings Goals", 0, BWCategoryType::Savings),
                category(0, "Debt Payments", 0, BWCategoryType::Debt),
            ],
        ),
        BWTemplateType::BiweeklyPaycheck => (
            "biweekly-paycheck",
            "Biweekly Paycheck",
            "Personal",
            "Give each paycheck a plan for bills, everyday spending, debt, and future needs.",
            vec![
                category(0, "Take-Home Pay", 0, BWCategoryType::Income),
                category(1, "Other Income", 0, BWCategoryType::Income),
                category(0, "Housing", 0, BWCategoryType::Expenses),
                category(1, "Utilities", 0, BWCategoryType::Expenses),
                category(2, "Phone & Internet", 0, BWCategoryType::Expenses),
                category(3, "Insurance", 0, BWCategoryType::Expenses),
                category(4, "Groceries", 0, BWCategoryType::Expenses),
                category(5, "Dining Out", 0, BWCategoryType::Expenses),
                category(6, "Transportation", 0, BWCategoryType::Expenses),
                category(7, "Health & Personal Care", 0, BWCategoryType::Expenses),
                category(8, "Childcare & Dependents", 0, BWCategoryType::Expenses),
                category(9, "Fun & Entertainment", 0, BWCategoryType::Expenses),
                category(10, "Giving", 0, BWCategoryType::Expenses),
                category(11, "Miscellaneous", 0, BWCategoryType::Expenses),
                category(0, "Emergency Fund", 0, BWCategoryType::Savings),
                category(1, "Annual Bills & Repairs", 0, BWCategoryType::Savings),
                category(2, "Retirement", 0, BWCategoryType::Savings),
                category(3, "Savings Goals", 0, BWCategoryType::Savings),
                category(0, "Credit Card Payments", 0, BWCategoryType::Debt),
                category(1, "Loan Payments", 0, BWCategoryType::Debt),
            ],
        ),
        BWTemplateType::FreelancerMonthly => (
            "freelancer-monthly",
            "Freelancer Monthly",
            "Business",
            "Plan client income, business costs, owner pay, and reserves for taxes and quieter months.",
            vec![
                category(0, "Project Payments", 0, BWCategoryType::Income),
                category(1, "Retainers", 0, BWCategoryType::Income),
                category(2, "Other Revenue", 0, BWCategoryType::Income),
                category(0, "Owner Pay", 0, BWCategoryType::Expenses),
                category(1, "Subcontractors", 0, BWCategoryType::Expenses),
                category(2, "Software & Subscriptions", 0, BWCategoryType::Expenses),
                category(3, "Workspace & Utilities", 0, BWCategoryType::Expenses),
                category(4, "Phone & Internet", 0, BWCategoryType::Expenses),
                category(5, "Supplies & Equipment", 0, BWCategoryType::Expenses),
                category(6, "Marketing & Website", 0, BWCategoryType::Expenses),
                category(7, "Accounting & Legal", 0, BWCategoryType::Expenses),
                category(8, "Business Insurance", 0, BWCategoryType::Expenses),
                category(9, "Travel & Meetings", 0, BWCategoryType::Expenses),
                category(
                    10,
                    "Bank & Payment Processing Fees",
                    0,
                    BWCategoryType::Expenses,
                ),
                category(11, "Training & Memberships", 0, BWCategoryType::Expenses),
                category(0, "Tax Reserve", 0, BWCategoryType::Savings),
                category(1, "Income Buffer", 0, BWCategoryType::Savings),
                category(2, "Equipment Replacement", 0, BWCategoryType::Savings),
                category(0, "Business Loan Payments", 0, BWCategoryType::Debt),
                category(1, "Equipment Financing Payments", 0, BWCategoryType::Debt),
            ],
        ),
        BWTemplateType::SmallBusinessMonthly => (
            "small-business-monthly",
            "Small Business Monthly",
            "Business",
            "Plan monthly cash needs across sales, operating costs, taxes, reserves, and debt payments.",
            vec![
                category(0, "Product Sales", 0, BWCategoryType::Income),
                category(1, "Service Revenue", 0, BWCategoryType::Income),
                category(2, "Subscription Revenue", 0, BWCategoryType::Income),
                category(3, "Other Revenue", 0, BWCategoryType::Income),
                category(0, "Inventory & Materials", 0, BWCategoryType::Expenses),
                category(1, "Payroll & Benefits", 0, BWCategoryType::Expenses),
                category(2, "Owner Pay", 0, BWCategoryType::Expenses),
                category(3, "Contractors", 0, BWCategoryType::Expenses),
                category(4, "Rent & Utilities", 0, BWCategoryType::Expenses),
                category(5, "Software & Hosting", 0, BWCategoryType::Expenses),
                category(6, "Phone & Internet", 0, BWCategoryType::Expenses),
                category(7, "Marketing & Advertising", 0, BWCategoryType::Expenses),
                category(8, "Shipping & Delivery", 0, BWCategoryType::Expenses),
                category(9, "Supplies & Maintenance", 0, BWCategoryType::Expenses),
                category(10, "Business Insurance", 0, BWCategoryType::Expenses),
                category(11, "Accounting & Legal", 0, BWCategoryType::Expenses),
                category(12, "Licenses & Permits", 0, BWCategoryType::Expenses),
                category(
                    13,
                    "Bank & Payment Processing Fees",
                    0,
                    BWCategoryType::Expenses,
                ),
                category(14, "Taxes", 0, BWCategoryType::Expenses),
                category(0, "Operating Reserve", 0, BWCategoryType::Savings),
                category(1, "Equipment Replacement", 0, BWCategoryType::Savings),
                category(2, "Growth Fund", 0, BWCategoryType::Savings),
                category(0, "Business Loan Payments", 0, BWCategoryType::Debt),
                category(1, "Business Credit Payments", 0, BWCategoryType::Debt),
            ],
        ),
        BWTemplateType::EventPlanning => (
            "event-planning",
            "Event Planning",
            "Events",
            "Plan event funding, suppliers, guest needs, and a reserve for unexpected costs.",
            vec![
                category(0, "Event Budget", 0, BWCategoryType::Income),
                category(1, "Ticket Sales", 0, BWCategoryType::Income),
                category(2, "Sponsorships", 0, BWCategoryType::Income),
                category(3, "Vendor Fees", 0, BWCategoryType::Income),
                category(4, "Contributions", 0, BWCategoryType::Income),
                category(0, "Venue & Rentals", 0, BWCategoryType::Expenses),
                category(1, "Catering & Drinks", 0, BWCategoryType::Expenses),
                category(2, "Speakers & Entertainment", 0, BWCategoryType::Expenses),
                category(3, "Audio, Video & Lighting", 0, BWCategoryType::Expenses),
                category(4, "Decor & Signage", 0, BWCategoryType::Expenses),
                category(5, "Marketing & Ticketing", 0, BWCategoryType::Expenses),
                category(6, "Staff & Contractors", 0, BWCategoryType::Expenses),
                category(7, "Security & First Aid", 0, BWCategoryType::Expenses),
                category(8, "Insurance & Permits", 0, BWCategoryType::Expenses),
                category(9, "Travel & Accommodation", 0, BWCategoryType::Expenses),
                category(10, "Transport & Parking", 0, BWCategoryType::Expenses),
                category(11, "Cleaning & Waste", 0, BWCategoryType::Expenses),
                category(12, "Payment Processing Fees", 0, BWCategoryType::Expenses),
                category(
                    13,
                    "Accessibility & Guest Services",
                    0,
                    BWCategoryType::Expenses,
                ),
                category(0, "Contingency Reserve", 0, BWCategoryType::Savings),
                category(0, "Event Financing Payments", 0, BWCategoryType::Debt),
                category(1, "Supplier Credit Payments", 0, BWCategoryType::Debt),
            ],
        ),
        BWTemplateType::Vacation => (
            "vacation",
            "Vacation",
            "Travel",
            "Plan your travel budget, bookings, everyday trip spending, and an emergency buffer.",
            vec![
                category(0, "Travel Budget", 0, BWCategoryType::Income),
                category(
                    0,
                    "Flights & Long-Distance Travel",
                    0,
                    BWCategoryType::Expenses,
                ),
                category(1, "Accommodation", 0, BWCategoryType::Expenses),
                category(2, "Groceries & Dining", 0, BWCategoryType::Expenses),
                category(
                    3,
                    "Local Transport & Car Rental",
                    0,
                    BWCategoryType::Expenses,
                ),
                category(4, "Fuel, Tolls & Parking", 0, BWCategoryType::Expenses),
                category(5, "Activities & Excursions", 0, BWCategoryType::Expenses),
                category(6, "Travel Insurance", 0, BWCategoryType::Expenses),
                category(
                    7,
                    "Passports, Visas & Entry Fees",
                    0,
                    BWCategoryType::Expenses,
                ),
                category(8, "Baggage & Booking Fees", 0, BWCategoryType::Expenses),
                category(9, "Phone & Internet", 0, BWCategoryType::Expenses),
                category(10, "Travel Health & Supplies", 0, BWCategoryType::Expenses),
                category(11, "Souvenirs & Shopping", 0, BWCategoryType::Expenses),
                category(12, "Tips & Local Taxes", 0, BWCategoryType::Expenses),
                category(
                    13,
                    "Currency Exchange & ATM Fees",
                    0,
                    BWCategoryType::Expenses,
                ),
                category(0, "Emergency Buffer", 0, BWCategoryType::Savings),
            ],
        ),
        BWTemplateType::BusinessTrip => (
            "business-trip",
            "Business Trip",
            "Travel",
            "Plan your travel budget, work commitments, trip expenses, and an emergency buffer.",
            vec![
                category(0, "Travel Budget", 0, BWCategoryType::Income),
                category(
                    0,
                    "Flights & Long-Distance Travel",
                    0,
                    BWCategoryType::Expenses,
                ),
                category(1, "Accommodation", 0, BWCategoryType::Expenses),
                category(2, "Meals & Incidentals", 0, BWCategoryType::Expenses),
                category(
                    3,
                    "Local Transport & Car Rental",
                    0,
                    BWCategoryType::Expenses,
                ),
                category(4, "Fuel, Tolls & Parking", 0, BWCategoryType::Expenses),
                category(5, "Travel Insurance", 0, BWCategoryType::Expenses),
                category(
                    6,
                    "Passports, Visas & Entry Fees",
                    0,
                    BWCategoryType::Expenses,
                ),
                category(7, "Baggage & Booking Fees", 0, BWCategoryType::Expenses),
                category(8, "Phone & Internet", 0, BWCategoryType::Expenses),
                category(
                    9,
                    "Conference & Registration Fees",
                    0,
                    BWCategoryType::Expenses,
                ),
                category(10, "Workspace & Meeting Rooms", 0, BWCategoryType::Expenses),
                category(
                    11,
                    "Business Supplies & Printing",
                    0,
                    BWCategoryType::Expenses,
                ),
                category(12, "Client Hospitality", 0, BWCategoryType::Expenses),
                category(13, "Tips & Local Taxes", 0, BWCategoryType::Expenses),
                category(
                    14,
                    "Currency Exchange & ATM Fees",
                    0,
                    BWCategoryType::Expenses,
                ),
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
        setup_kind: "none".to_string(),
        categories,
    }
}

#[export]
pub fn template_catalog() -> Vec<BWTemplateCatalogEntry> {
    [
        BWTemplateType::BasicMonthly,
        BWTemplateType::Empty,
        BWTemplateType::WeeklyPersonal,
        BWTemplateType::BiweeklyPaycheck,
        BWTemplateType::FreelancerMonthly,
        BWTemplateType::SmallBusinessMonthly,
        BWTemplateType::EventPlanning,
        BWTemplateType::Vacation,
        BWTemplateType::BusinessTrip,
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
    if template == BWTemplateType::Empty {
        return BWBudget::new(title);
    }

    let details = template_details(template);
    let mut new_budget = BWBudget::new(title);
    for definition in details.categories {
        let template_category = create_category(
            definition.ordinal,
            definition.title,
            definition.amount_planned.value,
            definition.category_type,
        );
        new_budget = add_category(new_budget, template_category)
            .expect("built-in template categories must be valid");
    }
    new_budget
}

#[export]
pub fn budget_from_previous_budget(budget: BWBudget, title: String) -> Result<BWBudget, String> {
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
        for template in [BWTemplateType::Vacation, BWTemplateType::BusinessTrip] {
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
}
