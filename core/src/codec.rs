/* 
 * Budget Warden
 * Copyright (c) 2026 Lazarov & Co EOOD
 * Author: Nikola Lazarov
 *
 * Licensed under the Source-Available Educational License. 
 * See the LICENSE file in the project root for full terms.
 */

use boltffi::*;
use crate::models::BWBudget;

#[export]
pub fn encode_budget(budget: &BWBudget) -> Result<String, String> {
    serde_json::to_string_pretty(budget)
        .map_err(|e| format!("Failed to encode budget to JSON: {e}"))
}

#[export]
pub fn decode_budget(json: &str) -> Result<BWBudget, String> {
    serde_json::from_str(json)
        .map_err(|e| format!("Failed to decode budget from JSON: {e}"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::models::*;
    use crate::crdt::*;
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
        };

        let json = encode_budget(&budget).unwrap();
        let decoded = decode_budget(&json).unwrap();

        assert_eq!(decoded.id, budget.id);
        assert_eq!(decoded.title, "Test Budget");
        assert_eq!(decoded.schema_version, 2);
        assert_eq!(decoded.categories.len(), 1);
        assert_eq!(decoded.categories[0].title, "Salary");
        assert_eq!(decoded.categories[0].amount_planned.value, 480000);
        assert_eq!(decoded.categories[0].category_type, BWCategoryType::Income);
        assert_eq!(decoded.categories[0].transactions[0].title, "July Paycheck");
        assert_eq!(decoded.categories[0].transactions[0].date.year, 2026);
    }
}
