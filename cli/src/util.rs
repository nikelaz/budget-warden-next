use chrono::{Datelike, NaiveDate};
use serde_json::{Value, json};
use uuid::Uuid;

use crate::args::CategoryTypeArg;
use crate::error::{ApiError, usage_error};
use crate::protocol::MoneyInput;
use bw_core::models::{BWCategory, BWCategoryType, BWDate, BWMoneyAmount, BWTransaction};

pub fn category_type(value: CategoryTypeArg) -> BWCategoryType {
    match value {
        CategoryTypeArg::Income => BWCategoryType::Income,
        CategoryTypeArg::Expenses => BWCategoryType::Expenses,
        CategoryTypeArg::Savings => BWCategoryType::Savings,
        CategoryTypeArg::Debt => BWCategoryType::Debt,
    }
}

pub fn parse_category_type(value: &str) -> Result<BWCategoryType, ApiError> {
    match value.to_ascii_lowercase().as_str() {
        "income" => Ok(BWCategoryType::Income),
        "expenses" => Ok(BWCategoryType::Expenses),
        "savings" => Ok(BWCategoryType::Savings),
        "debt" => Ok(BWCategoryType::Debt),
        _ => Err(usage_error(format!("Unknown category type: {value}"))),
    }
}

pub fn category_type_name(value: BWCategoryType) -> &'static str {
    match value {
        BWCategoryType::Income => "income",
        BWCategoryType::Expenses => "expenses",
        BWCategoryType::Savings => "savings",
        BWCategoryType::Debt => "debt",
    }
}

pub fn money(value: &str) -> Result<BWMoneyAmount, ApiError> {
    let mut parts = value.split('.');
    let whole = parts.next().unwrap_or_default();
    let fraction = parts.next();
    if whole.is_empty()
        || !whole.bytes().all(|byte| byte.is_ascii_digit())
        || fraction.is_some_and(|fraction| {
            !(1..=2).contains(&fraction.len())
                || !fraction.bytes().all(|byte| byte.is_ascii_digit())
        })
        || parts.next().is_some()
    {
        return Err(usage_error(
            "Money must be a nonnegative decimal with at most two fractional digits",
        ));
    }
    bw_core::money::parse_money_amount(value.to_string(), None)
        .ok_or_else(|| usage_error(format!("Invalid money amount: {value}")))
}

pub fn money_input(input: &MoneyInput) -> Result<BWMoneyAmount, ApiError> {
    match input {
        MoneyInput::Decimal(value) => money(value),
        MoneyInput::MinorUnits { minor_units } => parse_minor_units(minor_units),
    }
}

fn parse_minor_units(text: &str) -> Result<BWMoneyAmount, ApiError> {
    if text.is_empty() || !text.bytes().all(|byte| byte.is_ascii_digit()) {
        return Err(usage_error(
            "Minor units must be a nonnegative integer string",
        ));
    }
    let value = text
        .parse::<i64>()
        .map_err(|_| usage_error("Minor units must be an integer string in range"))?;
    Ok(BWMoneyAmount { value })
}

pub fn money_pair(
    decimal: Option<&str>,
    minor_units: Option<&str>,
    default: Option<&str>,
) -> Result<Option<BWMoneyAmount>, ApiError> {
    if decimal.is_some() && minor_units.is_some() {
        return Err(usage_error(
            "Provide either a decimal amount or minor units, not both",
        ));
    }
    if let Some(value) = decimal {
        return money(value).map(Some);
    }
    if let Some(value) = minor_units {
        return parse_minor_units(value).map(Some);
    }
    default.map(money).transpose()
}

pub fn format_money(value: i64) -> String {
    let value = i128::from(value);
    let sign = if value < 0 { "-" } else { "" };
    let absolute = value.abs();
    format!("{sign}{}.{:02}", absolute / 100, absolute % 100)
}

pub fn date(text: &str) -> Result<BWDate, ApiError> {
    let parsed = NaiveDate::parse_from_str(text, "%Y-%m-%d")
        .map_err(|_| usage_error(format!("Date must be a valid YYYY-MM-DD value: {text}")))?;
    if parsed.format("%Y-%m-%d").to_string() != text {
        return Err(usage_error("Date must use YYYY-MM-DD format"));
    }
    Ok(BWDate {
        year: parsed.year(),
        month: parsed.month() as i32,
        day: parsed.day() as i32,
    })
}

pub fn date_text(date: BWDate) -> String {
    format!("{:04}-{:02}-{:02}", date.year, date.month, date.day)
}
pub fn date_value(date: BWDate) -> Value {
    json!(date_text(date))
}

pub fn category_value(category: &BWCategory) -> Value {
    json!({
        "id": category.id,
        "ordinal": category.ordinal,
        "title": category.title,
        "type": category_type_name(category.category_type),
        "planned_amount": format_money(category.amount_planned.value),
        "actual_amount": format_money(category.amount_actual.value),
        "accumulated_amount": format_money(category.amount_accumulated.value),
        "transaction_count": category.transactions.len(),
    })
}

pub fn transaction_value(transaction: &BWTransaction, category: &BWCategory) -> Value {
    json!({
        "id": transaction.id,
        "category_id": category.id,
        "category_title": category.title,
        "title": transaction.title,
        "description": transaction.description,
        "date": date_text(transaction.date),
        "amount": format_money(transaction.amount.value),
    })
}

pub fn parse_uuid_ref(
    value: &str,
    refs: &std::collections::HashMap<String, Uuid>,
) -> Result<Uuid, ApiError> {
    if let Some(local) = value.strip_prefix('$') {
        return refs.get(local).copied().ok_or_else(|| {
            ApiError::new(
                "unresolved_reference",
                format!("Unknown local reference: ${local}"),
                2,
            )
            .details(json!({"reference": local}))
        });
    }
    Uuid::parse_str(value).map_err(|_| usage_error(format!("Invalid UUID: {value}")))
}

pub fn validate_page(limit: usize) -> Result<(), ApiError> {
    if limit == 0 || limit > 1000 {
        return Err(usage_error("limit must be between 1 and 1000"));
    }
    Ok(())
}

pub fn find_category_mut(
    categories: &mut [BWCategory],
    id: Uuid,
) -> Result<&mut BWCategory, ApiError> {
    categories
        .iter_mut()
        .find(|category| category.id == id)
        .ok_or_else(|| crate::error::missing_entity("category", id.to_string()))
}

#[cfg(test)]
mod tests {
    use std::collections::HashMap;

    use super::*;

    #[test]
    fn money_parsing_keeps_decimal_and_minor_unit_values_exact() {
        assert_eq!(money("42.50").unwrap().value, 4_250);
        assert_eq!(
            money_input(&MoneyInput::MinorUnits {
                minor_units: "4250".to_string(),
            })
            .unwrap()
            .value,
            4_250
        );
        assert!(money("42.501").is_err());
        assert!(money("-1.00").is_err());
        for invalid in [".50", " 1.00", "1.00 ", "+1.00", "1,00"] {
            assert!(money(invalid).is_err(), "accepted {invalid:?}");
        }
        assert_eq!(money("92233720368547758.07").unwrap().value, i64::MAX);
        assert!(money("92233720368547758.08").is_err());
        for invalid in ["+100", " 100", "100 ", "9223372036854775808"] {
            assert!(money_pair(None, Some(invalid), None).is_err());
            assert!(
                money_input(&MoneyInput::MinorUnits {
                    minor_units: invalid.into()
                })
                .is_err()
            );
        }
        assert!(
            money_input(&MoneyInput::MinorUnits {
                minor_units: "-1".to_string(),
            })
            .is_err()
        );
    }

    #[test]
    fn money_pair_rejects_ambiguous_input() {
        assert!(money_pair(Some("1.00"), Some("100"), None).is_err());
        assert!(money_pair(None, None, None).unwrap().is_none());
        assert_eq!(
            money_pair(None, None, Some("1.25")).unwrap().unwrap().value,
            125
        );
    }

    #[test]
    fn date_parser_requires_a_real_canonical_calendar_date() {
        let leap_day = date("2024-02-29").unwrap();
        assert_eq!(date_text(leap_day), "2024-02-29");
        assert!(date("2026-02-29").is_err());
        assert!(date("2026-2-03").is_err());
    }

    #[test]
    fn local_uuid_references_resolve_and_unknown_names_fail() {
        let id = Uuid::new_v4();
        let refs = HashMap::from([("food".to_string(), id)]);
        assert_eq!(parse_uuid_ref("$food", &refs).unwrap(), id);
        assert_eq!(parse_uuid_ref(&id.to_string(), &refs).unwrap(), id);
        assert_eq!(
            parse_uuid_ref("$missing", &refs).unwrap_err().code,
            "unresolved_reference"
        );
    }

    #[test]
    fn page_limit_is_bounded() {
        assert!(validate_page(1).is_ok());
        assert!(validate_page(1000).is_ok());
        assert!(validate_page(0).is_err());
        assert!(validate_page(1001).is_err());
    }
}
