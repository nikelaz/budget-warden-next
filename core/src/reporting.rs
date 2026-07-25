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

use crate::models::{BWBudget, BWCategory, BWCategoryType, BWMoneyAmount};
use crate::validation::{checked_money_sum, validate_budget};

#[data]
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum BWReportingAmountMode {
    Planned,
    Actual,
}

#[data]
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum BWReportingComparisonRow {
    Income,
    Planned,
    Actual,
}

#[data]
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum BWReportingComponent {
    Income,
    Expenses,
    Savings,
    Debt,
}

#[data]
#[derive(Clone, PartialEq)]
pub struct BWReportingTotals {
    pub income: BWMoneyAmount,
    pub planned_spending: BWMoneyAmount,
    pub actual_spending: BWMoneyAmount,
    pub planned_savings: BWMoneyAmount,
    pub planned_allocation: BWMoneyAmount,
    pub actual_allocation: BWMoneyAmount,
    pub left_to_budget: i64,
}

#[data]
#[derive(Clone, PartialEq)]
pub struct BWReportingAllocationSegment {
    pub amount_mode: BWReportingAmountMode,
    pub category_type: BWCategoryType,
    pub amount: BWMoneyAmount,
}

#[data]
#[derive(Clone, PartialEq)]
pub struct BWReportingCategorySegment {
    pub amount_mode: BWReportingAmountMode,
    pub category_id: Uuid,
    pub category_type: BWCategoryType,
    pub title: String,
    pub amount: BWMoneyAmount,
}

#[data]
#[derive(Clone, PartialEq)]
pub struct BWReportingComparisonSegment {
    pub row: BWReportingComparisonRow,
    pub component: BWReportingComponent,
    pub amount: BWMoneyAmount,
}

#[data]
#[derive(Clone, PartialEq)]
pub struct BWReportingSummary {
    pub totals: BWReportingTotals,
    pub allocation_segments: Vec<BWReportingAllocationSegment>,
    pub category_segments: Vec<BWReportingCategorySegment>,
    pub comparison_segments: Vec<BWReportingComparisonSegment>,
}

fn amount_for_mode(
    category: &BWCategory,
    amount_mode: BWReportingAmountMode,
) -> BWMoneyAmount {
    match amount_mode {
        BWReportingAmountMode::Planned => category.amount_planned,
        BWReportingAmountMode::Actual => category.amount_actual,
    }
}

fn total_for_types(
    budget: &BWBudget,
    category_types: &[BWCategoryType],
    amount_mode: BWReportingAmountMode,
    context: &str,
) -> Result<BWMoneyAmount, String> {
    checked_money_sum(
        budget
            .categories
            .iter()
            .filter(|category| category_types.contains(&category.category_type))
            .map(|category| amount_for_mode(category, amount_mode)),
        context,
    )
}

fn component_for_category_type(
    category_type: BWCategoryType,
) -> BWReportingComponent {
    match category_type {
        BWCategoryType::Income => BWReportingComponent::Income,
        BWCategoryType::Expenses => BWReportingComponent::Expenses,
        BWCategoryType::Savings => BWReportingComponent::Savings,
        BWCategoryType::Debt => BWReportingComponent::Debt,
    }
}

#[export]
pub fn build_reporting_summary(
    budget: &BWBudget,
) -> Result<BWReportingSummary, String> {
    validate_budget(budget)?;

    let income = total_for_types(
        budget,
        &[BWCategoryType::Income],
        BWReportingAmountMode::Planned,
        "Income total",
    )?;
    let planned_spending = total_for_types(
        budget,
        &[BWCategoryType::Expenses, BWCategoryType::Debt],
        BWReportingAmountMode::Planned,
        "Planned spending total",
    )?;
    let actual_spending = total_for_types(
        budget,
        &[BWCategoryType::Expenses, BWCategoryType::Debt],
        BWReportingAmountMode::Actual,
        "Actual spending total",
    )?;
    let planned_savings = total_for_types(
        budget,
        &[BWCategoryType::Savings],
        BWReportingAmountMode::Planned,
        "Planned savings total",
    )?;
    let outflow_types = [
        BWCategoryType::Expenses,
        BWCategoryType::Savings,
        BWCategoryType::Debt,
    ];
    let planned_allocation = total_for_types(
        budget,
        &outflow_types,
        BWReportingAmountMode::Planned,
        "Planned allocation total",
    )?;
    let actual_allocation = total_for_types(
        budget,
        &outflow_types,
        BWReportingAmountMode::Actual,
        "Actual allocation total",
    )?;
    let left_to_budget = income
        .value
        .checked_sub(planned_spending.value)
        .and_then(|value| value.checked_sub(planned_savings.value))
        .ok_or_else(|| "Left to budget total is too large".to_string())?;

    let mut allocation_segments = Vec::new();
    let mut comparison_segments = Vec::new();

    if income.value > 0 {
        comparison_segments.push(BWReportingComparisonSegment {
            row: BWReportingComparisonRow::Income,
            component: BWReportingComponent::Income,
            amount: income,
        });
    }

    for amount_mode in [
        BWReportingAmountMode::Planned,
        BWReportingAmountMode::Actual,
    ] {
        for category_type in outflow_types {
            let amount = total_for_types(
                budget,
                &[category_type],
                amount_mode,
                "Reporting segment total",
            )?;
            if amount.value == 0 {
                continue;
            }

            allocation_segments.push(BWReportingAllocationSegment {
                amount_mode,
                category_type,
                amount,
            });
            comparison_segments.push(BWReportingComparisonSegment {
                row: match amount_mode {
                    BWReportingAmountMode::Planned => BWReportingComparisonRow::Planned,
                    BWReportingAmountMode::Actual => BWReportingComparisonRow::Actual,
                },
                component: component_for_category_type(category_type),
                amount,
            });
        }
    }

    let mut category_segments = Vec::new();
    for category in budget.ordered_categories(None) {
        for amount_mode in [
            BWReportingAmountMode::Planned,
            BWReportingAmountMode::Actual,
        ] {
            let amount = amount_for_mode(&category, amount_mode);
            if amount.value > 0 {
                category_segments.push(BWReportingCategorySegment {
                    amount_mode,
                    category_id: category.id,
                    category_type: category.category_type,
                    title: category.title.clone(),
                    amount,
                });
            }
        }
    }

    Ok(BWReportingSummary {
        totals: BWReportingTotals {
            income,
            planned_spending,
            actual_spending,
            planned_savings,
            planned_allocation,
            actual_allocation,
            left_to_budget,
        },
        allocation_segments,
        category_segments,
        comparison_segments,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::models::BWCategory;

    fn category(
        title: &str,
        category_type: BWCategoryType,
        ordinal: i32,
        planned: i64,
        actual: i64,
    ) -> BWCategory {
        BWCategory {
            id: Uuid::new_v4(),
            ordinal,
            title: title.to_string(),
            amount_planned: BWMoneyAmount { value: planned },
            amount_actual: BWMoneyAmount { value: actual },
            amount_accumulated: BWMoneyAmount { value: 0 },
            category_type,
            transactions: vec![],
        }
    }

    #[test]
    fn builds_checked_typed_reporting_summary() {
        let mut budget = BWBudget::new("Test".to_string());
        budget.categories = vec![
            category("Expense 2", BWCategoryType::Expenses, 2, 1_000, 900),
            category("Income", BWCategoryType::Income, 0, 10_000, 0),
            category("Savings", BWCategoryType::Savings, 0, 2_000, 0),
            category("Expense 1", BWCategoryType::Expenses, 1, 3_000, 2_100),
        ];

        let summary = build_reporting_summary(&budget).unwrap();

        assert_eq!(summary.totals.income.value, 10_000);
        assert_eq!(summary.totals.planned_spending.value, 4_000);
        assert_eq!(summary.totals.actual_spending.value, 3_000);
        assert_eq!(summary.totals.planned_savings.value, 2_000);
        assert_eq!(summary.totals.left_to_budget, 4_000);
        assert_eq!(
            summary
                .category_segments
                .iter()
                .filter(|segment| {
                    segment.amount_mode == BWReportingAmountMode::Planned
                        && segment.category_type == BWCategoryType::Expenses
                })
                .map(|segment| segment.title.as_str())
                .collect::<Vec<_>>(),
            vec!["Expense 1", "Expense 2"]
        );
        assert!(
            summary
                .allocation_segments
                .iter()
                .all(|segment| segment.amount.value > 0)
        );
    }

    #[test]
    fn allows_negative_left_to_budget() {
        let mut budget = BWBudget::new("Test".to_string());
        budget.categories = vec![
            category("Income", BWCategoryType::Income, 0, 100, 0),
            category("Expense", BWCategoryType::Expenses, 0, 200, 0),
        ];

        assert_eq!(
            build_reporting_summary(&budget)
                .unwrap()
                .totals
                .left_to_budget,
            -100
        );
    }

    #[test]
    fn rejects_negative_or_overflowing_amounts() {
        let mut negative = BWBudget::new("Negative".to_string());
        negative.categories = vec![category(
            "Expense",
            BWCategoryType::Expenses,
            0,
            -1,
            0,
        )];
        assert!(build_reporting_summary(&negative).is_err());

        let mut overflowing = BWBudget::new("Overflow".to_string());
        overflowing.categories = vec![
            category(
                "Expense 1",
                BWCategoryType::Expenses,
                0,
                i64::MAX,
                0,
            ),
            category("Expense 2", BWCategoryType::Expenses, 1, 1, 0),
        ];
        assert!(build_reporting_summary(&overflowing).is_err());
    }
}
