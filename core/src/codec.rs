/* 
 * Budget Warden
 * Copyright (c) 2026 Lazarov & Co EOOD
 * Author: Nikola Lazarov
 *
 * Licensed under the Source-Available Educational License. 
 * See the LICENSE file in the project root for full terms.
 */

use boltffi::*;
use crate::crdt::observe_budget_timestamps;
use crate::legacy_migration::migrate_legacy_budget;
use crate::models::{BWBudget, CURRENT_SCHEMA_VERSION};
use crate::validation::validate_budget;

const NEWER_SCHEMA_ERROR: &str = "This budget was created with a newer version of Budget Warden. Please update Budget Warden to open it.";

#[export]
pub fn encode_budget(budget: &BWBudget) -> Result<String, String> {
    validate_budget(budget)?;
    serde_json::to_string_pretty(budget)
        .map_err(|e| format!("Failed to encode budget to JSON: {e}"))
}

#[export]
pub fn decode_budget(json: &str, url: String) -> Result<BWBudget, String> {
    let value: serde_json::Value = serde_json::from_str(json)
        .map_err(|e| format!("Failed to decode budget from JSON: {e}"))?;

    let Some(schema_version) = value.get("schema_version") else {
        let budget = migrate_legacy_budget(value, url)?;
        validate_budget(&budget)?;
        observe_budget_timestamps(&budget);
        return Ok(budget);
    };
    let schema_version = schema_version.as_i64().ok_or_else(|| {
        "Failed to decode budget from JSON: schema_version must be an integer".to_string()
    })?;

    if schema_version > i64::from(CURRENT_SCHEMA_VERSION) {
        return Err(NEWER_SCHEMA_ERROR.to_string());
    }

    let mut budget: BWBudget = serde_json::from_value(value)
        .map_err(|e| format!("Failed to decode budget from JSON: {e}"))?;

    budget.url = Some(url);
    validate_budget(&budget)?;
    observe_budget_timestamps(&budget);

    Ok(budget)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::models::*;
    use crate::crdt::*;
    use chrono::{Datelike, Local};
    use uuid::Uuid;

    #[test]
    fn test_encode_budget_decode_round_trip() {
        let budget = BWBudget {
            id: Uuid::new_v4(),
            revision: 0,
            revision_id: Uuid::new_v4(),
            schema_version: 2,
            title: "Test Budget".to_string(),
            categories: vec![
                BWCategory {
                    id: Uuid::new_v4(),
                    ordinal: 0,
                    title: "Salary".to_string(),
                    amount_planned: BWMoneyAmount { value: 480000 },
                    amount_actual: BWMoneyAmount { value: 0 },
                    amount_accumulated: BWMoneyAmount { value: 0 },
                    category_type: BWCategoryType::Income,
                    transactions: vec![
                        BWTransaction {
                            id: Uuid::new_v4(),
                            title: "July Paycheck".to_string(),
                            description: String::new(),
                            date: BWDate { year: 2026, month: 7, day: 1 },
                            amount: BWMoneyAmount { value: 480000 },
                        }
                    ],
                }
            ],
            changes: CRDTChanges {
                budget: Vec::new(),
                categories: std::collections::HashMap::new(),
                transactions: std::collections::HashMap::new(),
                category_tombstones: std::collections::HashMap::new(),
                transaction_tombstones: std::collections::HashMap::new(),
            },
            url: Some(String::new()),
            requires_migration_writeback: false,
        };

        let json = encode_budget(&budget).unwrap();
        let decoded = decode_budget(&json, "/tmp/test-budget.bwbudget".to_string()).unwrap();

        assert_eq!(decoded.id, budget.id);
        assert_eq!(decoded.title, "Test Budget");
        assert_eq!(decoded.schema_version, 2);
        assert_eq!(decoded.categories.len(), 1);
        assert_eq!(decoded.categories[0].title, "Salary");
        assert_eq!(decoded.categories[0].amount_planned.value, 480000);
        assert_eq!(decoded.categories[0].category_type, BWCategoryType::Income);
        assert_eq!(decoded.categories[0].transactions[0].title, "July Paycheck");
        assert_eq!(decoded.categories[0].transactions[0].date.year, 2026);
        assert_eq!(decoded.url.as_deref(), Some("/tmp/test-budget.bwbudget"));
    }

    #[test]
    fn test_decode_budget_rejects_newer_schema_before_decoding_budget() {
        let json = serde_json::json!({
            "schema_version": CURRENT_SCHEMA_VERSION + 1,
        })
        .to_string();

        let error = decode_budget(&json, String::new())
            .err()
            .expect("newer schema should be rejected");

        assert_eq!(error, NEWER_SCHEMA_ERROR);
    }

    #[test]
    fn test_decode_budget_preserves_malformed_json_error() {
        let error = decode_budget("{", String::new())
            .err()
            .expect("malformed JSON should be rejected");

        assert!(error.starts_with("Failed to decode budget from JSON:"));
    }

    #[test]
    fn test_decode_budget_advances_hlc_past_loaded_future_changes() {
        use crate::app_state::initialize_core;
        use crate::domain::update_budget_title;

        let _ = initialize_core(Uuid::from_u128(0xC10C));
        let future_timestamp = HlcTimestamp {
            physical_ms: chrono::Utc::now().timestamp_millis() + 60_000,
            logical: 7,
            device_id: Uuid::from_u128(0xF07E),
        };
        let mut budget = BWBudget::new("Original".to_string());
        budget.changes.budget = vec![BudgetChange {
            change_id: Uuid::new_v4(),
            timestamp: future_timestamp.clone(),
            payload: Some(BudgetChangePayload {
                title: Some("Original".to_string()),
            }),
        }];
        let json = encode_budget(&budget).unwrap();

        let decoded = decode_budget(&json, "/tmp/future.budget".to_string()).unwrap();
        let updated = update_budget_title(decoded, "Renamed".to_string()).unwrap();

        assert!(updated.changes.budget[0].timestamp > future_timestamp);
    }

    #[test]
    fn test_decode_budget_migrates_live_legacy_fixture() {
        let json = include_str!("../tests/fixtures/legacy_budget.json");
        let legacy_revision_id =
            Uuid::parse_str("FD966378-22B3-4C83-A7E9-11D6F239AB5C").unwrap();

        let migrated = decode_budget(json, "/tmp/legacy.budget".to_string()).unwrap();

        assert_eq!(
            migrated.id,
            Uuid::parse_str("69191F81-08F1-4CCB-BB57-A3EAB49BD086").unwrap()
        );
        assert_eq!(migrated.revision, 2);
        assert_ne!(migrated.revision_id, legacy_revision_id);
        assert_eq!(migrated.schema_version, CURRENT_SCHEMA_VERSION);
        assert_eq!(migrated.title, "Old budget format");
        assert_eq!(migrated.categories.len(), 13);
        assert_eq!(migrated.categories[0].title, "Salary");
        assert_eq!(migrated.categories[0].amount_planned.value, 480000);
        assert_eq!(migrated.categories[0].category_type, BWCategoryType::Income);
        assert_eq!(migrated.categories[12].title, "Retirement");
        assert_eq!(migrated.url.as_deref(), Some("/tmp/legacy.budget"));
        assert!(migrated.requires_migration_writeback);

        assert_eq!(migrated.changes.budget.len(), 1);
        assert_eq!(
            migrated.changes.categories.len(),
            migrated.categories.len()
        );
        assert!(migrated.changes.transactions.is_empty());
        assert!(migrated.changes.category_tombstones.is_empty());
        assert!(migrated.changes.transaction_tombstones.is_empty());
        for category in &migrated.categories {
            let changes = migrated.changes.categories.get(&category.id).unwrap();
            assert_eq!(changes.len(), 5);
            for change in changes.values() {
                assert_eq!(change.timestamp.physical_ms, 0);
                assert_eq!(change.timestamp.logical, 1);
                assert_eq!(change.timestamp.device_id, legacy_revision_id);
            }
        }

        let encoded = encode_budget(&migrated).unwrap();
        let encoded_value: serde_json::Value = serde_json::from_str(&encoded).unwrap();
        assert_eq!(encoded_value["schema_version"], CURRENT_SCHEMA_VERSION);
        assert!(encoded_value.get("revisionId").is_none());
        assert!(encoded_value.get("requires_migration_writeback").is_none());
        assert_eq!(encoded_value["categories"][0]["amount_planned"], 480000);
        assert_eq!(encoded_value["categories"][0]["category_type"], "income");

        let decoded_again = decode_budget(&encoded, "/tmp/legacy.budget".to_string()).unwrap();
        assert_eq!(decoded_again.revision_id, migrated.revision_id);
        assert!(!decoded_again.requires_migration_writeback);
    }

    #[test]
    fn test_legacy_migration_converts_transactions_and_recomputes_actuals() {
        let json = serde_json::json!({
            "id": "00000000-0000-0000-0000-000000000001",
            "revision": 4,
            "revisionId": "00000000-0000-0000-0000-000000000002",
            "categories": [{
                "ordinal": 0,
                "amountActual": 999999,
                "amountPlanned": 10000,
                "transactions": [{
                    "id": "00000000-0000-0000-0000-000000000004",
                    "title": "Groceries",
                    "description": "Weekly shop",
                    "date": "2026-07-24T12:00:00Z",
                    "amount": 1234
                }, {
                    "id": "00000000-0000-0000-0000-000000000005",
                    "title": "Coffee",
                    "description": "",
                    "date": "2026-07-25T12:00:00Z",
                    "amount": 250
                }],
                "amountAccumulated": 500,
                "categoryType": 2,
                "id": "00000000-0000-0000-0000-000000000003",
                "title": "Food"
            }],
            "title": "Transactions"
        })
        .to_string();

        let migrated = decode_budget(&json, String::new()).unwrap();
        let category = &migrated.categories[0];
        let expected_date = chrono::DateTime::parse_from_rfc3339("2026-07-24T12:00:00Z")
            .unwrap()
            .with_timezone(&Local);

        assert_eq!(category.amount_actual.value, 1484);
        assert_eq!(category.transactions.len(), 2);
        assert_eq!(category.transactions[0].description, "Weekly shop");
        assert_eq!(category.transactions[0].date.year, expected_date.year());
        assert_eq!(
            category.transactions[0].date.month,
            expected_date.month() as i32
        );
        assert_eq!(
            category.transactions[0].date.day,
            expected_date.day() as i32
        );
        assert_eq!(migrated.changes.transactions.len(), 2);
        for changes in migrated.changes.transactions.values() {
            assert_eq!(changes.len(), 5);
        }
    }

    #[test]
    fn test_legacy_migration_rejects_duplicate_transaction_ids() {
        let transaction = serde_json::json!({
            "id": "00000000-0000-0000-0000-000000000004",
            "title": "Duplicate",
            "description": "",
            "date": "2026-07-24T12:00:00Z",
            "amount": 100
        });
        let json = serde_json::json!({
            "id": "00000000-0000-0000-0000-000000000001",
            "revision": 1,
            "revisionId": "00000000-0000-0000-0000-000000000002",
            "categories": [{
                "ordinal": 0,
                "amountActual": 200,
                "amountPlanned": 200,
                "transactions": [transaction.clone(), transaction],
                "amountAccumulated": 0,
                "categoryType": 2,
                "id": "00000000-0000-0000-0000-000000000003",
                "title": "Food"
            }],
            "title": "Duplicates"
        })
        .to_string();

        let error = decode_budget(&json, String::new())
            .err()
            .expect("duplicate transaction ids must be rejected");
        assert!(error.contains("duplicate transaction id"));
    }

    #[test]
    fn test_legacy_migration_rejects_unknown_fields() {
        let mut value: serde_json::Value =
            serde_json::from_str(include_str!("../tests/fixtures/legacy_budget.json")).unwrap();
        value["crdt"] = serde_json::json!({});

        let error = decode_budget(&value.to_string(), String::new())
            .err()
            .expect("unknown legacy fields must be rejected");
        assert!(error.contains("unknown field `crdt`"));
    }

    #[test]
    fn test_legacy_migration_rejects_invalid_values() {
        let fixture: serde_json::Value =
            serde_json::from_str(include_str!("../tests/fixtures/legacy_budget.json")).unwrap();

        let mut invalid_category_type = fixture.clone();
        invalid_category_type["categories"][0]["categoryType"] = serde_json::json!(99);

        let mut negative_money = fixture.clone();
        negative_money["categories"][0]["amountPlanned"] = serde_json::json!(-1);

        let mut duplicate_category = fixture.clone();
        let first_category = duplicate_category["categories"][0].clone();
        duplicate_category["categories"]
            .as_array_mut()
            .unwrap()
            .push(first_category);

        let mut invalid_date = fixture.clone();
        invalid_date["categories"][0]["transactions"] = serde_json::json!([{
            "id": "00000000-0000-0000-0000-000000000004",
            "title": "Invalid date",
            "description": "",
            "date": "not-a-date",
            "amount": 100
        }]);

        let mut actual_overflow = fixture;
        actual_overflow["categories"][0]["transactions"] = serde_json::json!([{
            "id": "00000000-0000-0000-0000-000000000004",
            "title": "Large",
            "description": "",
            "date": "2026-07-24T12:00:00Z",
            "amount": i64::MAX
        }, {
            "id": "00000000-0000-0000-0000-000000000005",
            "title": "Overflow",
            "description": "",
            "date": "2026-07-24T12:00:00Z",
            "amount": 1
        }]);

        for (value, expected_error) in [
            (invalid_category_type, "unsupported category type"),
            (negative_money, "negative money amount"),
            (duplicate_category, "duplicate category id"),
            (invalid_date, "invalid date for transaction"),
            (actual_overflow, "actual amount overflow"),
        ] {
            let error = decode_budget(&value.to_string(), String::new())
                .err()
                .expect("invalid legacy values must be rejected");
            assert!(
                error.contains(expected_error),
                "expected error containing {expected_error:?}, got {error:?}"
            );
        }
    }
}
