/*
 * Budget Warden
 * Copyright (c) 2026 Lazarov & Co EOOD
 * Author: Nikola Lazarov
 *
 * Licensed under the Source-Available Educational License.
 * See the LICENSE file in the project root for full terms.
 */

//! Setup questions that turn a few answers into planned amounts for a
//! template's categories.
//!
//! Each template's setup is one Rust function that asks its questions in
//! order. A question returns the user's answer, or its suggestion while
//! unanswered, so later suggestions and later questions can depend on earlier
//! answers. Running the same function yields both the questions to show and
//! the planned amounts, so the two never disagree. Apps render the questions
//! generically and call core again whenever an answer changes.

use crate::models::*;
use crate::templates::{
    BWTemplateCategoryDefinition, BWTemplateType, budget_from_definitions, template_catalog,
};
use boltffi::*;

#[data]
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum BWSetupQuestionKind {
    /// An amount of money; values are in hundredths, like `BWMoneyAmount`.
    Money,
    /// A whole percentage from 0 to 100.
    Percent,
    /// A whole, non-negative number such as travelers or nights.
    Count,
    /// One of `choices`; answered with the choice ID.
    Choice,
    /// Yes or no; answered with 1 or 0.
    Toggle,
}

#[data]
#[derive(Clone, PartialEq, Debug)]
pub struct BWSetupChoice {
    pub id: String,
    pub title: String,
}

#[data]
#[derive(Clone, PartialEq, Debug)]
pub struct BWSetupQuestion {
    /// Stable within a template; answers refer to it.
    pub id: String,
    pub kind: BWSetupQuestionKind,
    pub title: String,
    /// Help text. For suggestions that depend on earlier answers, explains why.
    pub detail: String,
    /// The value used while the question is unanswered (Money, Percent, Count).
    pub suggested_value: i64,
    /// The choice used while the question is unanswered (Choice).
    pub suggested_choice: String,
    pub choices: Vec<BWSetupChoice>,
    /// Required questions should be answered before creating the budget.
    pub optional: bool,
    /// The smallest accepted value (Count).
    pub min_value: i64,
    /// The question this one follows up on, shown together with it; empty
    /// for top-level questions.
    pub parent_id: String,
}

#[data]
#[derive(Clone, PartialEq, Debug)]
pub struct BWSetupAnswer {
    pub question_id: String,
    /// Money in hundredths, a whole percentage, or a count.
    pub value: i64,
    /// The choice ID for Choice questions; empty otherwise.
    pub choice: String,
}

#[data]
#[derive(Clone)]
pub struct BWSetupPreview {
    /// Every category the budget will be created with, in template order.
    pub categories: Vec<BWTemplateCategoryDefinition>,
    pub income: BWMoneyAmount,
    /// Planned expenses, savings, and debt.
    pub allocated: BWMoneyAmount,
    /// `income - allocated`; negative when the plan exceeds the income.
    pub unallocated: BWMoneyAmount,
    /// Short remarks about the result, such as categories left at zero.
    pub notes: Vec<String>,
}

/// The questions to show for `template_id`, given the answers so far.
/// Questions can appear, disappear, or change their suggestion as answers
/// change; answers to questions that are no longer shown are ignored.
#[export]
pub fn template_setup_questions(
    template_id: String,
    answers: Vec<BWSetupAnswer>,
) -> Result<Vec<BWSetupQuestion>, String> {
    Ok(run(&template_id, &answers)?.0)
}

/// The categories and planned amounts the answers produce. Unanswered
/// questions use their suggestions.
#[export]
pub fn template_setup_preview(
    template_id: String,
    answers: Vec<BWSetupAnswer>,
) -> Result<BWSetupPreview, String> {
    Ok(run(&template_id, &answers)?.1)
}

/// Creates a budget from a template and setup answers. The result matches
/// `template_setup_preview` for the same answers.
#[export]
pub fn budget_from_template_setup(
    template_id: String,
    title: String,
    answers: Vec<BWSetupAnswer>,
) -> Result<BWBudget, String> {
    let (_, preview) = run(&template_id, &answers)?;
    budget_from_definitions(title, preview.categories)
}

fn run(
    template_id: &str,
    answers: &[BWSetupAnswer],
) -> Result<(Vec<BWSetupQuestion>, BWSetupPreview), String> {
    let entry = template_catalog()
        .into_iter()
        .find(|entry| entry.id == template_id)
        .ok_or_else(|| format!("Unknown budget template ID '{template_id}'."))?;
    let mut setup = Setup {
        answers,
        questions: vec![],
    };
    let plan = match entry.template_type {
        BWTemplateType::Empty => Plan::default(),
        BWTemplateType::BasicMonthly => personal(&mut setup, Period::Month)?,
        BWTemplateType::WeeklyPersonal => personal(&mut setup, Period::Week)?,
        BWTemplateType::FreelancerMonthly => freelancer(&mut setup)?,
        BWTemplateType::SmallBusinessMonthly => small_business(&mut setup)?,
        BWTemplateType::Vacation => trip(&mut setup)?,
    };

    let mut categories = entry.categories;
    for (title, amount) in &plan.amounts {
        let category = categories
            .iter_mut()
            .find(|category| category.title == *title)
            .unwrap_or_else(|| panic!("setup category '{title}' is not in template '{template_id}'"));
        category.amount_planned = BWMoneyAmount { value: *amount };
    }
    let total = |income: bool| -> Result<i64, String> {
        categories
            .iter()
            .filter(|category| (category.category_type == BWCategoryType::Income) == income)
            .try_fold(0i64, |sum, category| sum.checked_add(category.amount_planned.value))
            .ok_or_else(overflow)
    };
    let income = total(true)?;
    let allocated = total(false)?;
    let unallocated = income.checked_sub(allocated).ok_or_else(overflow)?;
    Ok((
        setup.questions,
        BWSetupPreview {
            categories,
            income: BWMoneyAmount { value: income },
            allocated: BWMoneyAmount { value: allocated },
            unallocated: BWMoneyAmount { value: unallocated },
            notes: plan.notes,
        },
    ))
}

// MARK: - Question collection

struct Setup<'a> {
    answers: &'a [BWSetupAnswer],
    questions: Vec<BWSetupQuestion>,
}

impl Setup<'_> {
    fn answer(&self, id: &str) -> Option<&BWSetupAnswer> {
        self.answers.iter().rev().find(|answer| answer.question_id == id)
    }

    fn ask(&mut self, id: &str, kind: BWSetupQuestionKind, title: String, detail: String) -> &mut BWSetupQuestion {
        self.questions.push(BWSetupQuestion {
            id: id.to_string(),
            kind,
            title,
            detail,
            suggested_value: 0,
            suggested_choice: String::new(),
            choices: vec![],
            optional: true,
            min_value: 0,
            parent_id: String::new(),
        });
        self.questions.last_mut().unwrap()
    }

    fn money(&mut self, id: &str, title: String, detail: &str, suggested: i64, optional: bool) -> Result<i64, String> {
        let question = self.ask(id, BWSetupQuestionKind::Money, title.clone(), detail.to_string());
        question.suggested_value = suggested;
        question.optional = optional;
        let value = self.answer(id).map_or(suggested, |answer| answer.value);
        if value < 0 {
            return Err(format!("{title} cannot be negative."));
        }
        Ok(value)
    }

    fn percent(&mut self, id: &str, title: &str, detail: String, suggested: i64) -> Result<i64, String> {
        let question = self.ask(id, BWSetupQuestionKind::Percent, title.to_string(), detail);
        question.suggested_value = suggested;
        let value = self.answer(id).map_or(suggested, |answer| answer.value);
        if !(0..=100).contains(&value) {
            return Err(format!("{title} must be between 0% and 100%."));
        }
        Ok(value)
    }

    fn count(&mut self, id: &str, title: &str, detail: &str, suggested: i64, min: i64) -> Result<i64, String> {
        let question = self.ask(id, BWSetupQuestionKind::Count, title.to_string(), detail.to_string());
        question.suggested_value = suggested;
        question.optional = false;
        question.min_value = min;
        let value = self.answer(id).map_or(suggested, |answer| answer.value);
        if value < min || value > 100_000 {
            return Err(format!("{title} must be between {min} and 100,000."));
        }
        Ok(value)
    }

    /// Asks follow-up questions that belong with `parent`.
    fn under<T>(&mut self, parent: &str, ask: impl FnOnce(&mut Self) -> Result<T, String>) -> Result<T, String> {
        let start = self.questions.len();
        let result = ask(self)?;
        for question in &mut self.questions[start..] {
            if question.parent_id.is_empty() {
                question.parent_id = parent.to_string();
            }
        }
        Ok(result)
    }

    fn toggle(&mut self, id: &str, title: &str, detail: &str, suggested: bool) -> Result<bool, String> {
        let question = self.ask(id, BWSetupQuestionKind::Toggle, title.to_string(), detail.to_string());
        question.suggested_value = i64::from(suggested);
        question.optional = false;
        match self.answer(id).map_or(i64::from(suggested), |answer| answer.value) {
            0 => Ok(false),
            1 => Ok(true),
            _ => Err(format!("{title} must be yes or no.")),
        }
    }

    fn choice(
        &mut self,
        id: &str,
        title: &str,
        detail: &str,
        choices: &[(&str, &str)],
        suggested: &str,
    ) -> Result<String, String> {
        let question = self.ask(id, BWSetupQuestionKind::Choice, title.to_string(), detail.to_string());
        question.suggested_choice = suggested.to_string();
        question.optional = false;
        question.choices = choices
            .iter()
            .map(|(id, title)| BWSetupChoice { id: id.to_string(), title: title.to_string() })
            .collect();
        let value = self
            .answer(id)
            .map_or(suggested, |answer| answer.choice.as_str())
            .to_string();
        if !choices.iter().any(|(choice, _)| *choice == value) {
            return Err(format!("'{value}' is not an option for: {title}"));
        }
        Ok(value)
    }
}

#[derive(Default)]
struct Plan {
    amounts: Vec<(&'static str, i64)>,
    notes: Vec<String>,
}

impl Plan {
    fn set(&mut self, title: &'static str, amount: i64) {
        self.amounts.push((title, amount));
    }

    fn split(&mut self, total: i64, weights: &[(&'static str, i64)]) -> Result<(), String> {
        for (title, amount) in split(total, weights)? {
            self.set(title, amount);
        }
        Ok(())
    }
}

// MARK: - Arithmetic

fn overflow() -> String {
    "The amounts are too large.".to_string()
}

/// `amount × numerator ÷ denominator`, rounded to the nearest whole currency
/// unit.
fn scale(amount: i64, numerator: i64, denominator: i64) -> Result<i64, String> {
    if denominator == 0 {
        return Ok(0);
    }
    let exact = i128::from(amount) * i128::from(numerator);
    let units = (exact + i128::from(denominator) * 50) / (i128::from(denominator) * 100);
    i64::try_from(units * 100).map_err(|_| overflow())
}

fn percent_of(amount: i64, percent: i64) -> Result<i64, String> {
    scale(amount, percent, 100)
}

fn multiply(values: &[i64]) -> Result<i64, String> {
    values
        .iter()
        .try_fold(1i64, |product, value| product.checked_mul(*value))
        .ok_or_else(overflow)
}

fn subtract(amount: i64, parts: &[i64]) -> Result<i64, String> {
    parts
        .iter()
        .try_fold(amount, |rest, part| rest.checked_sub(*part))
        .ok_or_else(overflow)
}

/// The whole percentage `part` is of `whole`; 0 when there is no whole.
fn share(part: i64, whole: i64) -> i64 {
    if whole <= 0 {
        return 0;
    }
    (i128::from(part) * 100 / i128::from(whole)).clamp(0, 1000) as i64
}

/// Splits `total` across categories in proportion to `weights`, in whole
/// currency units. Rounding goes to the first category so the parts add up
/// exactly to `total`.
fn split(total: i64, weights: &[(&'static str, i64)]) -> Result<Vec<(&'static str, i64)>, String> {
    let total = total.max(0);
    let weight_sum: i64 = weights.iter().map(|(_, weight)| weight).sum();
    let mut parts = weights
        .iter()
        .map(|(title, weight)| Ok((*title, scale(total, *weight, weight_sum)?)))
        .collect::<Result<Vec<_>, String>>()?;
    let assigned = parts.iter().try_fold(0i64, |sum, (_, part)| sum.checked_add(*part)).ok_or_else(overflow)?;
    if let Some(first) = parts.first_mut() {
        first.1 = (first.1 + total - assigned).max(0);
    }
    Ok(parts)
}

fn over_budget_note(what: &str) -> String {
    format!("{what} more than the money available, so the flexible categories are at 0. Lower an amount above or review the plan after creating it.")
}

// MARK: - Personal

#[derive(Clone, Copy)]
enum Period {
    Month,
    Week,
}

impl Period {
    fn per_year(self) -> i64 {
        match self {
            Period::Month => 12,
            Period::Week => 52,
        }
    }

    fn name(self) -> &'static str {
        match self {
            Period::Month => "month",
            Period::Week => "week",
        }
    }

    /// Converts a monthly amount to this period.
    fn from_monthly(self, monthly: i64) -> Result<i64, String> {
        match self {
            Period::Month => Ok(monthly),
            Period::Week => scale(monthly, 12, self.per_year()),
        }
    }
}

/// The suggested savings rate, from how much of pay housing and debt take.
fn suggested_savings(committed: i64, debt: i64) -> (i64, String) {
    let free = 100 - committed;
    let mut rate = match free {
        60.. => 20,
        50..=59 => 15,
        40..=49 => 10,
        25..=39 => 5,
        _ => 0,
    };
    if debt >= 20 {
        rate = rate.min(5);
    } else if debt >= 10 && rate > 5 {
        rate -= 5;
    }
    let reason = if committed == 0 {
        "Saving 20% builds an emergency fund and retirement savings.".to_string()
    } else if debt >= 10 {
        format!("Housing and debt take {committed}% of your pay, and paying debt down comes first, so start with {rate}%.")
    } else {
        format!("Housing and debt take {committed}% of your pay, so {rate}% is a realistic start.")
    };
    (rate, reason)
}

/// The suggested giving rate, from what remains after fixed costs and saving.
fn suggested_giving(committed: i64, savings: i64, debt: i64) -> (i64, String) {
    let free = 100 - committed - savings;
    let rate = match free {
        _ if debt >= 10 => 0,
        55.. => 10,
        45..=54 => 5,
        _ => 0,
    };
    let reason = match rate {
        0 => "Your plan is already tight, so the suggestion is 0%. You can still set an amount.",
        _ => "Donations, gifts, and support for others.",
    };
    (rate, reason.to_string())
}

fn personal(setup: &mut Setup, period: Period) -> Result<Plan, String> {
    let mut plan = Plan::default();
    let name = period.name();
    let pay = setup.money(
        "pay",
        format!("What is your take-home pay per {name}?"),
        "Your pay after taxes and deductions, plus any other regular income.",
        0,
        false,
    )?;
    plan.set("Salary", pay);

    let housing_type = setup.choice(
        "housing",
        "What is your housing situation?",
        "",
        &[
            ("rent", "I rent"),
            ("mortgage", "I pay a mortgage"),
            ("own", "I own my home outright"),
            ("family", "I live with family"),
        ],
        "rent",
    )?;
    let (housing_title, housing_detail, housing_optional) = match housing_type.as_str() {
        "rent" => ("How much is your rent per month?", "Include building fees you pay with it.", false),
        "mortgage" => ("What is your mortgage payment per month?", "Include property tax or insurance if they are part of the payment.", false),
        "own" => ("What do property tax, insurance, and upkeep cost per month?", "Leave at 0 if you are not sure yet.", true),
        _ => ("How much do you contribute to the household per month?", "Leave at 0 if you do not contribute.", true),
    };
    let housing_monthly = setup.under("housing", |setup| {
        setup.money("housing_payment", housing_title.to_string(), housing_detail, 0, housing_optional)
    })?;
    let housing = period.from_monthly(housing_monthly)?;

    let debt_monthly = setup.money(
        "debt",
        "How much do you pay toward debts per month?".to_string(),
        "Credit cards, loans, and other required payments. Your mortgage is already counted under housing.",
        0,
        true,
    )?;
    let debt = period.from_monthly(debt_monthly)?;

    let committed = share(housing.checked_add(debt).ok_or_else(overflow)?, pay);
    let debt_share = share(debt, pay);
    let (savings_suggestion, savings_reason) = suggested_savings(committed, debt_share);
    let savings_rate = setup.percent("savings", "How much of your pay do you want to save?", savings_reason, savings_suggestion)?;
    let (giving_suggestion, giving_reason) = suggested_giving(committed, savings_rate, debt_share);
    let giving_rate = setup.percent("giving", "How much do you want to give?", giving_reason, giving_suggestion)?;

    let savings = percent_of(pay, savings_rate)?;
    let giving = percent_of(pay, giving_rate)?;
    // A small savings rate goes entirely to the emergency fund first.
    let emergency = if savings_rate <= 5 { savings } else { scale(savings, 40, 100)? };
    plan.set("Housing", housing);
    plan.set("Debt Payments", debt);
    plan.set("Giving", giving);
    plan.set("Emergency Fund", emergency);
    plan.set("Retirement", savings - emergency);

    let rest = subtract(pay, &[housing, debt, savings, giving])?;
    if rest < 0 {
        plan.notes.push(over_budget_note("Housing, debt, saving, and giving take"));
    }
    let utilities = if housing_type == "family" { 0 } else { 280 };
    plan.split(
        rest,
        &[
            ("Food", 640),
            ("Transportation", 240),
            ("Insurance", 300),
            ("Utilities", utilities),
            ("Fun & Entertainment", 200),
            ("Personal Care", 180),
            ("Health & Fitness", 150),
            ("Miscellaneous", 150),
        ],
    )?;
    Ok(plan)
}

// MARK: - Business

fn freelancer(setup: &mut Setup) -> Result<Plan, String> {
    let mut plan = Plan::default();
    let revenue = setup.money(
        "revenue",
        "What do you typically earn from clients per month?".to_string(),
        "Use an average of the last few months if your income varies.",
        0,
        false,
    )?;
    let costs = setup.money(
        "business_costs",
        "What do your business costs come to per month?".to_string(),
        "Software, workspace, equipment, accounting, marketing, and other running costs. The suggestion is 15% of your income.",
        percent_of(revenue, 15)?,
        false,
    )?;
    let tax_rate = setup.percent(
        "tax",
        "How much should you set aside for taxes?",
        "Check your local rates. 25–30% covers income tax and social contributions in many countries.".to_string(),
        25,
    )?;
    let committed = share(costs, revenue) + tax_rate;
    let buffer_suggestion = match committed {
        ..=45 => 10,
        46..=60 => 5,
        _ => 0,
    };
    let buffer_rate = setup.percent(
        "buffer",
        "How much do you want to keep for slow months?",
        format!("Costs and taxes take {committed}% of your income, so {buffer_suggestion}% keeps your own pay steady."),
        buffer_suggestion,
    )?;

    let tax = percent_of(revenue, tax_rate)?;
    let buffer = percent_of(revenue, buffer_rate)?;
    plan.set("Client Income", revenue);
    plan.set("Tax Reserve", tax);
    plan.set("Income Buffer", buffer);
    plan.set("Business Costs", costs);
    let owner_pay = subtract(revenue, &[costs, tax, buffer])?;
    if owner_pay < 0 {
        plan.notes.push("Costs, taxes, and the buffer add up to more than your income, so Owner Pay is 0.".to_string());
    }
    plan.set("Owner Pay", owner_pay.max(0));
    Ok(plan)
}

fn small_business(setup: &mut Setup) -> Result<Plan, String> {
    let mut plan = Plan::default();
    let revenue = setup.money(
        "revenue",
        "What are your sales per month?".to_string(),
        "Use a typical month, before any costs.",
        0,
        false,
    )?;
    let cogs_rate = setup.percent(
        "cost_of_goods",
        "What share of sales goes to inventory and materials?",
        "Use 0% for a service business.".to_string(),
        30,
    )?;
    let payroll = setup.money(
        "payroll",
        "What is your payroll per month, including benefits?".to_string(),
        "Leave at 0 if you have no employees.",
        0,
        true,
    )?;
    let rent = setup.money(
        "rent",
        "What do rent and utilities cost per month?".to_string(),
        "Leave at 0 if you work from home.",
        0,
        true,
    )?;
    let cogs = percent_of(revenue, cogs_rate)?;
    let operating = percent_of(revenue, 10)?;
    let profit = subtract(revenue, &[cogs, payroll, rent, operating])?;
    let tax_rate = setup.percent(
        "tax",
        "How much of your profit should you set aside for taxes?",
        format!(
            "Other running costs are planned at 10% of sales, which leaves a profit of about {}% of sales. Check your local tax rate.",
            share(profit.max(0), revenue)
        ),
        25,
    )?;

    let tax = percent_of(profit.max(0), tax_rate)?;
    let after_tax = subtract(profit, &[tax])?;
    if after_tax < 0 {
        plan.notes.push("Costs add up to more than sales, so Owner Pay and the Operating Reserve are 0.".to_string());
    }
    let reserve = scale(after_tax.max(0), 30, 100)?;
    plan.set("Sales", revenue);
    plan.set("Inventory & Materials", cogs);
    plan.set("Payroll & Benefits", payroll);
    plan.set("Rent & Utilities", rent);
    plan.set("Tax Reserve", tax);
    plan.set("Operating Reserve", reserve);
    plan.set("Owner Pay", subtract(after_tax.max(0), &[reserve])?);
    plan.set("Operating Costs", operating);
    Ok(plan)
}

// MARK: - Travel

fn trip(setup: &mut Setup) -> Result<Plan, String> {
    let mut plan = Plan::default();
    // Typical shares of a trip's total, used for suggestions.
    let (tickets_share, accommodation_share, per_diem_share) = (25, 35, 25);
    let total = setup.money(
        "total",
        "What is your total budget for the trip?".to_string(),
        "Everything included. The amounts below are suggested from it. Leave at 0 to plan only what you enter below.",
        0,
        true,
    )?;
    let share_note = |share: i64| {
        if total > 0 {
            format!(" The suggestion is about {share}% of your total budget.")
        } else {
            String::new()
        }
    };
    let travelers = setup.count("travelers", "How many people are traveling?", "", 1, 1)?;
    let has_tickets = setup.toggle(
        "has_tickets",
        "Are you buying tickets to get there?",
        "Flights, trains, buses, or ferries. Turn off if you are driving or the tickets are already paid.",
        true,
    )?;
    let tickets = if has_tickets {
        setup.under("has_tickets", |setup| {
            setup.money(
                "tickets_cost",
                "What do the tickets cost in total?".to_string(),
                &format!("For everyone, there and back.{}", share_note(tickets_share)),
                percent_of(total, tickets_share)?,
                true,
            )
        })?
    } else {
        0
    };
    let nights = setup.count("nights", "How many nights are you staying?", "Use 0 for a day trip.", 7, 0)?;
    let accommodation = if nights > 0 {
        setup.under("nights", |setup| {
            let pricing = setup.choice(
                "accommodation_pricing",
                "How do you want to enter the accommodation cost?",
                "",
                &[("per_night", "Price per night"), ("total", "Total for the whole stay")],
                "per_night",
            )?;
            if pricing == "per_night" {
                let nightly = setup.money(
                    "nightly_cost",
                    "What does accommodation cost per night?".to_string(),
                    &format!("The total for everyone, not per person.{}", share_note(accommodation_share)),
                    scale(total, accommodation_share, 100 * nights)?,
                    true,
                )?;
                multiply(&[nights, nightly])
            } else {
                setup.money(
                    "accommodation_total",
                    "What does accommodation cost for the whole stay?".to_string(),
                    &format!("The total for everyone and every night.{}", share_note(accommodation_share)),
                    percent_of(total, accommodation_share)?,
                    true,
                )
            }
        })?
    } else {
        0
    };
    // A trip lasts one day more than its nights; a day trip lasts one day.
    let days = nights + 1;
    let per_diem = setup.money(
        "per_diem",
        "What is the daily allowance (per diem) for each person?".to_string(),
        &format!(
            "A per diem is what one person spends on an ordinary day away: meals and drinks, coffee, local transport, tips, and small purchases. Planned for {days} {}.{}",
            if days == 1 { "day" } else { "days" },
            share_note(per_diem_share)
        ),
        scale(total, per_diem_share, 100 * travelers * days)?,
        true,
    )?;

    let daily_spending = multiply(&[travelers, days, per_diem])?;
    let estimated = [tickets, accommodation, daily_spending]
        .iter()
        .try_fold(0i64, |sum, amount| sum.checked_add(*amount))
        .ok_or_else(overflow)?;
    plan.set("Getting There", tickets);
    plan.set("Accommodation", accommodation);
    plan.set("Per Diem", daily_spending);
    plan.set("Travel Budget", total.max(estimated));
    if total == 0 {
        return Ok(plan);
    }
    if total < estimated {
        plan.notes.push("These costs are more than the total budget. Raise the total or lower an amount.".to_string());
        return Ok(plan);
    }
    // What remains after a 5% buffer goes to activities and extras.
    let buffer = percent_of(total, 5)?.min(total - estimated);
    plan.set("Emergency Buffer", buffer);
    plan.set("Activities & Extras", subtract(total, &[estimated, buffer])?);
    Ok(plan)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::app_state::initialize_core;
    use crate::validation::validate_budget;
    use uuid::Uuid;

    fn money(id: &str, units: i64) -> BWSetupAnswer {
        BWSetupAnswer { question_id: id.into(), value: units * 100, choice: String::new() }
    }

    fn number(id: &str, value: i64) -> BWSetupAnswer {
        BWSetupAnswer { question_id: id.into(), value, choice: String::new() }
    }

    fn pick(id: &str, choice: &str) -> BWSetupAnswer {
        BWSetupAnswer { question_id: id.into(), value: 0, choice: choice.into() }
    }

    fn amount(preview: &BWSetupPreview, title: &str) -> i64 {
        preview.categories.iter().find(|category| category.title == title).unwrap().amount_planned.value / 100
    }

    fn question<'a>(questions: &'a [BWSetupQuestion], id: &str) -> Option<&'a BWSetupQuestion> {
        questions.iter().find(|question| question.id == id)
    }

    #[test]
    fn every_template_runs_with_suggestions_only() {
        for entry in template_catalog() {
            let questions = template_setup_questions(entry.id.clone(), vec![]).unwrap();
            assert_eq!(questions.is_empty(), entry.template_type == BWTemplateType::Empty, "{}", entry.id);
            let preview = template_setup_preview(entry.id.clone(), vec![]).unwrap();
            assert_eq!(preview.categories.len(), entry.categories.len());
        }
    }

    #[test]
    fn personal_monthly_allocates_all_pay() {
        let preview = template_setup_preview(
            "basic-monthly".into(),
            vec![money("pay", 4000), pick("housing", "rent"), money("housing_payment", 1200)],
        )
        .unwrap();
        assert_eq!(amount(&preview, "Salary"), 4000);
        assert_eq!(amount(&preview, "Housing"), 1200);
        // Rent is 30% of pay, leaving 70% free: save 20%.
        assert_eq!(amount(&preview, "Emergency Fund") + amount(&preview, "Retirement"), 800);
        // 50% remains after rent and saving, so giving is 5%.
        assert_eq!(amount(&preview, "Giving"), 200);
        assert_eq!(preview.unallocated.value, 0);
        assert!(preview.notes.is_empty());
    }

    #[test]
    fn suggestions_drop_as_fixed_costs_and_debt_rise() {
        let suggestion = |answers: Vec<BWSetupAnswer>, id: &str| {
            question(&template_setup_questions("basic-monthly".into(), answers).unwrap(), id)
                .unwrap()
                .suggested_value
        };
        let comfortable = vec![money("pay", 5000), money("housing_payment", 1000)];
        let tight = vec![money("pay", 2000), money("housing_payment", 1300)];
        let indebted = vec![money("pay", 5000), money("housing_payment", 1000), money("debt", 800)];
        assert_eq!(suggestion(comfortable.clone(), "savings"), 20);
        assert_eq!(suggestion(comfortable, "giving"), 10);
        assert_eq!(suggestion(tight.clone(), "savings"), 5);
        assert_eq!(suggestion(tight, "giving"), 0);
        assert_eq!(suggestion(indebted.clone(), "savings"), 15);
        assert_eq!(suggestion(indebted, "giving"), 0);
    }

    #[test]
    fn housing_question_follows_the_housing_choice() {
        let title = |choice: &str| {
            let questions =
                template_setup_questions("basic-monthly".into(), vec![pick("housing", choice)]).unwrap();
            let housing = question(&questions, "housing_payment").unwrap();
            (housing.title.clone(), housing.optional)
        };
        assert!(title("rent").0.contains("rent"));
        assert!(!title("rent").1);
        assert!(title("own").1);
        assert!(template_setup_preview("basic-monthly".into(), vec![pick("housing", "castle")]).is_err());
    }

    #[test]
    fn weekly_converts_monthly_bills_to_the_week() {
        let preview = template_setup_preview(
            "weekly-personal".into(),
            vec![money("pay", 1000), money("housing_payment", 1300), money("debt", 260)],
        )
        .unwrap();
        assert_eq!(amount(&preview, "Housing"), 300);
        assert_eq!(amount(&preview, "Debt Payments"), 60);
        assert_eq!(preview.unallocated.value, 0);
    }

    #[test]
    fn overspent_personal_plan_is_reported() {
        let preview = template_setup_preview(
            "basic-monthly".into(),
            vec![money("pay", 1000), money("housing_payment", 1200)],
        )
        .unwrap();
        assert_eq!(amount(&preview, "Food"), 0);
        assert!(preview.unallocated.value < 0);
        assert_eq!(preview.notes.len(), 1);
    }

    #[test]
    fn freelancer_pays_the_owner_what_is_left() {
        let preview = template_setup_preview("freelancer-monthly".into(), vec![money("revenue", 6000)]).unwrap();
        // Costs 15% (900), tax 25% (1500), buffer 10% (600).
        assert_eq!(amount(&preview, "Tax Reserve"), 1500);
        assert_eq!(amount(&preview, "Income Buffer"), 600);
        assert_eq!(amount(&preview, "Owner Pay"), 3000);
        assert_eq!(preview.unallocated.value, 0);
    }

    #[test]
    fn small_business_reserves_tax_on_profit() {
        let preview = template_setup_preview(
            "small-business-monthly".into(),
            vec![money("revenue", 20000), money("payroll", 5000), money("rent", 2000)],
        )
        .unwrap();
        // Profit = 20000 − 6000 − 5000 − 2000 − 2000 = 5000; tax 25%.
        assert_eq!(amount(&preview, "Tax Reserve"), 1250);
        assert_eq!(amount(&preview, "Operating Reserve") + amount(&preview, "Owner Pay"), 3750);
        assert_eq!(preview.unallocated.value, 0);
    }

    #[test]
    fn trip_adds_up_what_is_entered_without_a_total() {
        let answers = vec![
            number("travelers", 2),
            money("tickets_cost", 300),
            number("nights", 4),
            money("nightly_cost", 150),
            money("per_diem", 45),
        ];
        let preview = template_setup_preview("vacation".into(), answers.clone()).unwrap();
        // Five days: one more than the nights.
        assert_eq!(amount(&preview, "Getting There"), 300);
        assert_eq!(amount(&preview, "Accommodation"), 600);
        assert_eq!(amount(&preview, "Per Diem"), 450);
        assert_eq!(amount(&preview, "Travel Budget"), 1350);
        assert_eq!(preview.unallocated.value, 0);

        let mut with_total = answers;
        with_total.push(money("total", 2000));
        let preview = template_setup_preview("vacation".into(), with_total).unwrap();
        assert_eq!(amount(&preview, "Emergency Buffer"), 100);
        assert_eq!(amount(&preview, "Activities & Extras"), 550);
        assert_eq!(preview.unallocated.value, 0);
    }

    #[test]
    fn trip_tickets_can_be_turned_off() {
        let questions = template_setup_questions("vacation".into(), vec![number("has_tickets", 0)]).unwrap();
        assert!(question(&questions, "tickets_cost").is_none());
        let questions = template_setup_questions("vacation".into(), vec![]).unwrap();
        assert_eq!(question(&questions, "has_tickets").unwrap().kind, BWSetupQuestionKind::Toggle);
        assert!(question(&questions, "tickets_cost").is_some());
        assert!(template_setup_preview("vacation".into(), vec![number("has_tickets", 2)]).is_err());
    }

    #[test]
    fn follow_up_questions_name_their_parent() {
        let questions = template_setup_questions("vacation".into(), vec![]).unwrap();
        assert_eq!(question(&questions, "tickets_cost").unwrap().parent_id, "has_tickets");
        assert_eq!(question(&questions, "nightly_cost").unwrap().parent_id, "nights");
        assert_eq!(question(&questions, "has_tickets").unwrap().parent_id, "");
    }

    #[test]
    fn trip_suggestions_follow_the_total_budget() {
        let answers = vec![money("total", 3500), number("travelers", 2), number("nights", 6)];
        let questions = template_setup_questions("vacation".into(), answers.clone()).unwrap();
        assert_eq!(questions[0].id, "total");
        // Tickets 25% of 3500; accommodation 35% over 6 nights; per diem 25% over 2 people × 7 days.
        assert_eq!(question(&questions, "tickets_cost").unwrap().suggested_value, 87500);
        assert_eq!(question(&questions, "nightly_cost").unwrap().suggested_value, 20400);
        assert_eq!(question(&questions, "per_diem").unwrap().suggested_value, 6300);
        let preview = template_setup_preview("vacation".into(), answers).unwrap();
        assert_eq!(amount(&preview, "Travel Budget"), 3500);
        assert_eq!(preview.unallocated.value, 0);
    }

    #[test]
    fn accommodation_can_be_entered_for_the_whole_stay() {
        let answers = vec![number("nights", 4), pick("accommodation_pricing", "total"), money("accommodation_total", 700)];
        let questions = template_setup_questions("vacation".into(), answers.clone()).unwrap();
        assert!(question(&questions, "accommodation_total").is_some());
        assert!(question(&questions, "nightly_cost").is_none());
        let preview = template_setup_preview("vacation".into(), answers).unwrap();
        assert_eq!(amount(&preview, "Accommodation"), 700);
    }

    #[test]
    fn day_trips_skip_the_accommodation_questions() {
        let answers = vec![number("nights", 0), money("per_diem", 40)];
        let questions = template_setup_questions("vacation".into(), answers.clone()).unwrap();
        assert!(question(&questions, "accommodation_pricing").is_none());
        assert!(question(&questions, "nightly_cost").is_none());
        assert_eq!(amount(&template_setup_preview("vacation".into(), answers).unwrap(), "Per Diem"), 40);
        assert!(template_setup_preview("vacation".into(), vec![number("travelers", 0)]).is_err());
    }

    #[test]
    fn negative_and_out_of_range_answers_are_rejected() {
        assert!(template_setup_preview("basic-monthly".into(), vec![money("pay", -1)]).is_err());
        assert!(template_setup_preview("basic-monthly".into(), vec![number("savings", 101)]).is_err());
        assert!(template_setup_preview("vacation".into(), vec![number("travelers", 100_000), number("per_diem", i64::MAX)]).is_err());
    }

    #[test]
    fn created_budget_matches_the_preview() {
        let _ = initialize_core(Uuid::from_u128(0x7E57));
        let answers = vec![money("pay", 3000), money("housing_payment", 900)];
        let preview = template_setup_preview("weekly-personal".into(), answers.clone()).unwrap();
        let budget = budget_from_template_setup("weekly-personal".into(), "Week 1".into(), answers).unwrap();
        validate_budget(&budget).unwrap();
        assert_eq!(budget.categories.len(), preview.categories.len());
        for (category, definition) in budget.categories.iter().zip(&preview.categories) {
            assert_eq!(category.title, definition.title);
            assert_eq!(category.amount_planned.value, definition.amount_planned.value);
        }
    }
}
