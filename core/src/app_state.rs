/* 
 * Budget Warden
 * Copyright (c) 2026 Lazarov & Co EOOD
 * Author: Nikola Lazarov
 *
 * Licensed under the Source-Available Educational License. 
 * See the LICENSE file in the project root for full terms.
 */

use std::sync::OnceLock;
use std::sync::Mutex;
use crate::crdt::HlcTimestamp;
use boltffi::*;
use uuid::Uuid;

static APP_STATE: OnceLock<AppState> = OnceLock::new();

pub struct AppState {
    pub device_id: Uuid,
    pub last_hlc: Mutex<HlcTimestamp>,
}

#[export]
pub fn initialize_core(device_id: Uuid) -> Result<(), String> {
    APP_STATE
        .set(AppState {
            device_id,
            last_hlc: Mutex::new(HlcTimestamp {
                physical_ms: 0,
                logical: 0,
                device_id,
            }),
        })
        .map_err(|_| "Rust core is already initialized".to_string())
}

pub fn app_state() -> &'static AppState {
    // it's ok to panic here in case we try to use functions
    // without initializing the app
    APP_STATE.get().unwrap()
}
