use bw_core::app_state::{get_clock_floor, initialize_core_with_clock_floor};
use bw_core::codec::{decode_portable_budget, encode_budget, observe_budget_clock};
use bw_core::crdt::{budget_content_is_equal, reconcile_budget_snapshots, HlcTimestamp};
use bw_core::domain::update_budget_title;
use bw_core::models::BWBudget;
use uuid::Uuid;

#[test]
fn server_operations_need_no_client_state_and_clock_exhaustion_is_checked() {
    let budget = BWBudget::new("Portable".to_string());
    let decoded = decode_portable_budget(&encode_budget(&budget).unwrap()).unwrap();
    let merged = reconcile_budget_snapshots(budget, decoded).unwrap();
    assert!(get_clock_floor().is_err());
    assert!(budget_content_is_equal(
        &merged,
        &reconcile_budget_snapshots(merged.clone(), merged.clone()).unwrap()
    ));

    // Simulate restoring a future clock floor after a process restart.
    initialize_core_with_clock_floor(Uuid::from_u128(123), i64::MAX - 1, i32::MAX).unwrap();
    let updated = update_budget_title(merged, "Updated".to_string()).unwrap();
    let floor = get_clock_floor().unwrap();
    assert_eq!((floor.physical_ms, floor.logical), (i64::MAX, 0));
    let mut exhausted = updated;
    exhausted.changes.budget[0].timestamp = HlcTimestamp {
        physical_ms: i64::MAX,
        logical: i32::MAX,
        device_id: Uuid::from_u128(456),
    };
    observe_budget_clock(&exhausted).unwrap();
    assert!(update_budget_title(exhausted, "Cannot advance".to_string()).is_err());
    assert_eq!(get_clock_floor().unwrap().logical, i32::MAX);
}
