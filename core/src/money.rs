/*
 * Budget Warden
 * Copyright (c) 2026 Lazarov & Co EOOD
 * Author: Nikola Lazarov
 *
 * Licensed under the Source-Available Educational License.
 * See the LICENSE file in the project root for full terms.
 */

use boltffi::*;

use crate::models::BWMoneyAmount;
use crate::validation::{checked_money_sum, validate_money_amount};

#[export]
pub fn parse_money_amount(
    text: String,
    empty_value: Option<i64>,
) -> Option<BWMoneyAmount> {
    let value = text.trim();
    if value.is_empty() {
        let amount = BWMoneyAmount {
            value: empty_value?,
        };
        return validate_money_amount(amount, "Money amount")
            .is_ok()
            .then_some(amount);
    }

    let normalized = value.replace(',', ".");
    let mut parts = normalized.split('.');
    let whole_text = parts.next()?;
    let fraction_text = parts.next();

    if parts.next().is_some()
        || !whole_text.chars().all(|character| character.is_ascii_digit())
        || fraction_text.is_some_and(|fraction| {
            !(1..=2).contains(&fraction.len())
                || !fraction.chars().all(|character| character.is_ascii_digit())
        })
    {
        return None;
    }

    let whole = if whole_text.is_empty() {
        0
    } else {
        whole_text.parse::<i64>().ok()?
    };
    let fraction = match fraction_text {
        None => 0,
        Some(text) if text.len() == 1 => text.parse::<i64>().ok()?.checked_mul(10)?,
        Some(text) => text.parse::<i64>().ok()?,
    };
    let value = whole.checked_mul(100)?.checked_add(fraction)?;

    Some(BWMoneyAmount { value })
}

#[export]
pub fn format_money_input(amount: BWMoneyAmount) -> Result<String, String> {
    validate_money_amount(amount, "Money amount")?;
    Ok(format!("{}.{:02}", amount.value / 100, amount.value % 100))
}

#[export]
pub fn sum_money_amounts(
    amounts: Vec<BWMoneyAmount>,
) -> Result<BWMoneyAmount, String> {
    checked_money_sum(amounts, "Money amount total")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_supported_money_input() {
        assert_eq!(parse_money_amount("12".to_string(), None).unwrap().value, 1_200);
        assert_eq!(parse_money_amount("12.3".to_string(), None).unwrap().value, 1_230);
        assert_eq!(parse_money_amount(",45".to_string(), None).unwrap().value, 45);
        assert_eq!(parse_money_amount("".to_string(), Some(0)).unwrap().value, 0);
    }

    #[test]
    fn rejects_invalid_or_out_of_range_money_input() {
        assert!(parse_money_amount("-1".to_string(), None).is_none());
        assert!(parse_money_amount("12.".to_string(), None).is_none());
        assert!(parse_money_amount("12.345".to_string(), None).is_none());
        assert!(parse_money_amount("abc".to_string(), None).is_none());
        assert!(parse_money_amount(i64::MAX.to_string(), None).is_none());
        assert!(parse_money_amount("".to_string(), Some(-1)).is_none());
    }

    #[test]
    fn formats_and_sums_checked_money() {
        assert_eq!(
            format_money_input(BWMoneyAmount { value: 1_230 }).unwrap(),
            "12.30"
        );
        assert_eq!(
            sum_money_amounts(vec![
                BWMoneyAmount { value: 100 },
                BWMoneyAmount { value: 200 },
            ])
            .unwrap()
            .value,
            300
        );
        assert!(
            sum_money_amounts(vec![
                BWMoneyAmount { value: i64::MAX },
                BWMoneyAmount { value: 1 },
            ])
            .is_err()
        );
        assert!(format_money_input(BWMoneyAmount { value: -1 }).is_err());
    }
}
