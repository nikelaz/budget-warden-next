use std::ffi::OsString;
use std::fs;
use std::path::PathBuf;

use budget_warden_linux::store::{AppState, BudgetTemplate};
use bw_core::models::{BWCategoryType, BWMoneyAmount};
use chrono::NaiveDate;
use uuid::Uuid;

struct TestHome {
    root: PathBuf,
    previous_config: Option<OsString>,
}

impl TestHome {
    fn new() -> Self {
        let root = std::env::temp_dir().join(format!("bw-linux-e2e-{}", Uuid::new_v4()));
        fs::create_dir_all(&root).unwrap();
        let previous_config = std::env::var_os("XDG_CONFIG_HOME");
        // This integration binary has a single test; keeping its preferences isolated
        // exercises AppState::new without touching the developer's real config.
        unsafe { std::env::set_var("XDG_CONFIG_HOME", root.join("config")) };
        Self {
            root,
            previous_config,
        }
    }

    fn budget_path(&self) -> PathBuf {
        self.root.join("household.budget")
    }
}

impl Drop for TestHome {
    fn drop(&mut self) {
        match self.previous_config.take() {
            Some(value) => unsafe { std::env::set_var("XDG_CONFIG_HOME", value) },
            None => unsafe { std::env::remove_var("XDG_CONFIG_HOME") },
        }
        let _ = fs::remove_dir_all(&self.root);
    }
}

#[test]
fn monthly_budget_transaction_reporting_and_reopen_flow() {
    let home = TestHome::new();
    let path = home.budget_path();
    let mut app = AppState::new().unwrap();
    app.set_currency("EUR".to_string()).unwrap();
    app.create_budget("  Household  ", &BudgetTemplate::BasicMonthly, &path)
        .unwrap();

    let initial = app.budget.as_ref().unwrap();
    assert_eq!(initial.title, "Household");
    assert!(
        !initial.categories.is_empty(),
        "monthly template should supply categories"
    );
    let income_id = initial
        .categories
        .iter()
        .find(|category| category.category_type == BWCategoryType::Income)
        .expect("monthly template has an income category")
        .id;
    let planned_income = initial
        .categories
        .iter()
        .find(|category| category.id == income_id)
        .unwrap()
        .amount_planned
        .value;
    let source_expense_id = initial
        .categories
        .iter()
        .find(|category| category.category_type == BWCategoryType::Expenses)
        .expect("monthly template has expense categories")
        .id;

    app.create_transaction(
        income_id,
        "Paycheck",
        "Employer",
        NaiveDate::from_ymd_opt(2026, 10, 1).unwrap(),
        500_000,
    )
    .unwrap();
    app.create_transaction(
        source_expense_id,
        "Rent",
        "October rent",
        NaiveDate::from_ymd_opt(2026, 10, 2).unwrap(),
        125_000,
    )
    .unwrap();
    app.create_category("Housing", 150_000, BWCategoryType::Expenses)
        .unwrap();
    let target_id = app
        .budget
        .as_ref()
        .unwrap()
        .categories
        .iter()
        .find(|category| category.title == "Housing")
        .unwrap()
        .id;
    let (_, rent) = app
        .transaction(
            app.budget
                .as_ref()
                .unwrap()
                .categories
                .iter()
                .find(|category| category.id == source_expense_id)
                .unwrap()
                .transactions[0]
                .id,
        )
        .unwrap();
    app.save_transaction(
        source_expense_id,
        target_id,
        bw_core::models::BWTransaction {
            title: "Rent".to_string(),
            description: "Paid by transfer".to_string(),
            amount: BWMoneyAmount { value: 130_000 },
            ..rent
        },
    )
    .unwrap();

    let summary = app.reporting_summary().unwrap();
    assert_eq!(summary.totals.income.value, planned_income);
    assert_eq!(summary.totals.actual_spending.value, 130_000);
    assert_eq!(
        summary.totals.left_to_budget,
        summary.totals.income.value
            - summary.totals.planned_spending.value
            - summary.totals.planned_savings.value
    );
    assert_eq!(
        app.budget
            .as_ref()
            .unwrap()
            .categories
            .iter()
            .find(|category| category.id == source_expense_id)
            .unwrap()
            .amount_actual
            .value,
        0
    );
    assert_eq!(
        app.budget
            .as_ref()
            .unwrap()
            .categories
            .iter()
            .find(|category| category.id == target_id)
            .unwrap()
            .amount_actual
            .value,
        130_000
    );

    let mut reopened = AppState::new().unwrap();
    reopened.open_budget(&path).unwrap();
    assert_eq!(reopened.currency, "EUR");
    assert_eq!(reopened.budget.as_ref().unwrap().title, "Household");
    let (category_id, persisted_rent) = reopened
        .transaction(
            reopened
                .budget
                .as_ref()
                .unwrap()
                .categories
                .iter()
                .find(|category| category.title == "Housing")
                .unwrap()
                .transactions[0]
                .id,
        )
        .unwrap();
    assert_eq!(category_id, target_id);
    assert_eq!(persisted_rent.description, "Paid by transfer");
    assert_eq!(
        (
            persisted_rent.date.year,
            persisted_rent.date.month,
            persisted_rent.date.day
        ),
        (2026, 10, 2)
    );
    assert_eq!(
        reopened
            .reporting_summary()
            .unwrap()
            .totals
            .actual_spending
            .value,
        130_000
    );

    reopened
        .delete_transaction(target_id, persisted_rent.id)
        .unwrap();
    reopened.delete_category(target_id).unwrap();
    let mut final_budget = AppState::new().unwrap();
    final_budget.open_budget(&path).unwrap();
    assert!(
        final_budget
            .budget
            .as_ref()
            .unwrap()
            .categories
            .iter()
            .all(|category| category.id != target_id)
    );
    assert_eq!(
        final_budget
            .reporting_summary()
            .unwrap()
            .totals
            .actual_spending
            .value,
        0
    );
}
