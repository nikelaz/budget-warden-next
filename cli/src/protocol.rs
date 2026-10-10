use serde::{Deserialize, Serialize};
use serde_json::Value;
use uuid::Uuid;

pub const PROTOCOL_VERSION: u32 = 1;

#[derive(Debug, Serialize)]
pub struct Envelope {
    pub protocol_version: u32,
    pub ok: bool,
    pub data: Value,
    pub error: Option<crate::error::ApiError>,
    pub meta: Option<Meta>,
}

#[derive(Debug, Clone, Serialize)]
pub struct Meta {
    pub command: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub budget_id: Option<Uuid>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub revision: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub revision_id: Option<Uuid>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub write_occurred: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub migration_status: Option<String>,
}

impl Meta {
    pub fn command(command: &str) -> Self {
        Self {
            command: command.to_string(),
            budget_id: None,
            revision: None,
            revision_id: None,
            write_occurred: None,
            migration_status: None,
        }
    }
    pub fn budget(
        mut self,
        budget_id: Uuid,
        revision: i64,
        revision_id: Uuid,
        write_occurred: bool,
    ) -> Self {
        self.budget_id = Some(budget_id);
        self.revision = Some(revision);
        self.revision_id = Some(revision_id);
        self.write_occurred = Some(write_occurred);
        self
    }
    pub fn migration(mut self, required: bool) -> Self {
        self.migration_status = Some(if required { "required" } else { "current" }.to_string());
        self
    }
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ApplyRequest {
    pub version: u32,
    pub file: String,
    #[serde(default)]
    pub expected_revision_id: Option<Uuid>,
    pub operations: Vec<Operation>,
}

#[derive(Debug, Deserialize)]
#[serde(tag = "op", rename_all = "snake_case", deny_unknown_fields)]
pub enum Operation {
    RenameBudget {
        title: String,
    },
    CreateCategory {
        #[serde(default)]
        local_ref: Option<String>,
        title: String,
        category_type: String,
        planned_amount: MoneyInput,
        #[serde(default)]
        accumulated_amount: Option<MoneyInput>,
        #[serde(default)]
        ordinal: Option<usize>,
    },
    UpdateCategory {
        id: String,
        #[serde(default)]
        title: Option<String>,
        #[serde(default)]
        category_type: Option<String>,
        #[serde(default)]
        planned_amount: Option<MoneyInput>,
        #[serde(default)]
        accumulated_amount: Option<MoneyInput>,
        #[serde(default)]
        ordinal: Option<usize>,
    },
    DeleteCategory {
        id: String,
    },
    MoveCategory {
        id: String,
        ordinal: usize,
    },
    CreateTransaction {
        #[serde(default)]
        local_ref: Option<String>,
        category_id: String,
        title: String,
        #[serde(default)]
        description: String,
        date: String,
        amount: MoneyInput,
    },
    UpdateTransaction {
        id: String,
        #[serde(default)]
        title: Option<String>,
        #[serde(default)]
        description: Option<String>,
        #[serde(default)]
        date: Option<String>,
        #[serde(default)]
        amount: Option<MoneyInput>,
    },
    DeleteTransaction {
        id: String,
    },
    MoveTransaction {
        id: String,
        category_id: String,
    },
}

#[derive(Debug, Clone, Deserialize)]
#[serde(untagged, deny_unknown_fields)]
pub enum MoneyInput {
    Decimal(String),
    MinorUnits { minor_units: String },
}

#[derive(Debug, Serialize)]
pub struct ApplyResult {
    pub version: u32,
    pub dry_run: bool,
    pub operation_count: usize,
    pub created_ids: Value,
    pub proposed_change_summary: Value,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn apply_request_deserializes_decimal_and_minor_unit_money() {
        let request: ApplyRequest = serde_json::from_str(
            r#"{
                "version": 1,
                "file": "budget.budget",
                "operations": [
                    {"op":"create_category","title":"Food","category_type":"expenses","planned_amount":"12.34"},
                    {"op":"create_category","title":"Travel","category_type":"expenses","planned_amount":{"minor_units":"1234"}}
                ]
            }"#,
        )
        .unwrap();
        assert_eq!(request.operations.len(), 2);
        assert!(matches!(
            &request.operations[0],
            Operation::CreateCategory {
                planned_amount: MoneyInput::Decimal(value),
                ..
            } if value == "12.34"
        ));
        assert!(matches!(
            &request.operations[1],
            Operation::CreateCategory {
                planned_amount: MoneyInput::MinorUnits { minor_units },
                ..
            } if minor_units == "1234"
        ));
    }

    #[test]
    fn apply_request_rejects_unknown_fields_at_both_levels() {
        let unknown_request_field = r#"{
            "version":1,"file":"budget.budget","unexpected":true,
            "operations":[{"op":"rename_budget","title":"New title"}]
        }"#;
        let unknown_operation_field = r#"{
            "version":1,"file":"budget.budget",
            "operations":[{"op":"rename_budget","title":"New title","unexpected":true}]
        }"#;
        assert!(serde_json::from_str::<ApplyRequest>(unknown_request_field).is_err());
        assert!(serde_json::from_str::<ApplyRequest>(unknown_operation_field).is_err());
    }
}
