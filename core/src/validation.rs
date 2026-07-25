/*
 * Budget Warden
 * Copyright (c) 2026 Lazarov & Co EOOD
 * Author: Nikola Lazarov
 *
 * Licensed under the Source-Available Educational License.
 * See the LICENSE file in the project root for full terms.
 */

use boltffi::*;

use crate::models::{BWBudget, BWCategory, BWMoneyAmount};

pub(crate) fn validate_money_amount(
    amount: BWMoneyAmount,
    context: &str,
) -> Result<(), String> {
    if amount.value < 0 {
        return Err(format!("{context} cannot be negative"));
    }

    Ok(())
}

pub(crate) fn checked_money_sum<I>(
    amounts: I,
    context: &str,
) -> Result<BWMoneyAmount, String>
where
    I: IntoIterator<Item = BWMoneyAmount>,
{
    let value = amounts.into_iter().try_fold(0_i64, |total, amount| {
        validate_money_amount(amount, context)?;
        total
            .checked_add(amount.value)
            .ok_or_else(|| format!("{context} is too large"))
    })?;

    Ok(BWMoneyAmount { value })
}

pub(crate) fn validate_category(category: &BWCategory) -> Result<(), String> {
    validate_money_amount(
        category.amount_planned,
        &format!("Category {} planned amount", category.id),
    )?;
    validate_money_amount(
        category.amount_actual,
        &format!("Category {} actual amount", category.id),
    )?;
    validate_money_amount(
        category.amount_accumulated,
        &format!("Category {} accumulated amount", category.id),
    )?;

    checked_money_sum(
        category.transactions.iter().map(|transaction| transaction.amount),
        &format!("Category {} transaction total", category.id),
    )?;

    Ok(())
}

#[export]
pub fn validate_budget(budget: &BWBudget) -> Result<(), String> {
    for category in &budget.categories {
        validate_category(category)?;
    }

    Ok(())
}
