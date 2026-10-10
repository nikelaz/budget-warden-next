/*
 * Budget Warden
 * Copyright (c) 2026 Lazarov & Co EOOD
 * Author: Nikola Lazarov
 *
 * Licensed under the Source-Available Educational License.
 * See the LICENSE file in the project root for full terms.
 */

use crate::crdt::HlcTimestamp;
use boltffi::*;
use serde::{Deserialize, Serialize};
use std::sync::Mutex;
use std::sync::OnceLock;
use uuid::Uuid;

static APP_STATE: OnceLock<AppState> = OnceLock::new();

pub struct AppState {
    pub device_id: Uuid,
    pub last_hlc: Mutex<HlcTimestamp>,
}

#[export]
pub fn initialize_core(device_id: Uuid) -> Result<(), String> {
    initialize_core_with_clock_floor(device_id, 0, 0)
}

/// Initialize the local mutation clock from durable app-owned state.
///
/// Native clients should persist the returned floor from `get_clock_floor`
/// alongside their device ID and pass it here on the next process launch.
#[export]
pub fn initialize_core_with_clock_floor(
    device_id: Uuid,
    physical_ms: i64,
    logical: i32,
) -> Result<(), String> {
    if device_id.is_nil() {
        return Err("Device ID cannot be empty".to_string());
    }
    if physical_ms < 0 {
        return Err("Clock floor physical time cannot be negative".to_string());
    }
    if logical < 0 {
        return Err("Clock floor logical time cannot be negative".to_string());
    }

    APP_STATE
        .set(AppState {
            device_id,
            last_hlc: Mutex::new(HlcTimestamp {
                physical_ms,
                logical,
                device_id,
            }),
        })
        .map_err(|_| "Rust core is already initialized".to_string())
}

#[data]
#[derive(Clone, Copy, Serialize, Deserialize)]
pub struct CoreClockFloor {
    pub physical_ms: i64,
    pub logical: i32,
}

#[export]
pub fn get_clock_floor() -> Result<CoreClockFloor, String> {
    let state = APP_STATE
        .get()
        .ok_or_else(|| "Rust core is not initialized".to_string())?;
    let last = state
        .last_hlc
        .lock()
        .map_err(|_| "Clock state is unavailable".to_string())?;
    Ok(CoreClockFloor {
        physical_ms: last.physical_ms,
        logical: last.logical,
    })
}

pub fn app_state() -> &'static AppState {
    // it's ok to panic here in case we try to use functions
    // without initializing the app
    APP_STATE.get().unwrap()
}

pub(crate) fn initialized_app_state() -> Option<&'static AppState> {
    APP_STATE.get()
}
