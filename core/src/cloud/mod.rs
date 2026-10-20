/*
 * Budget Warden
 * Copyright (c) 2026 Lazarov & Co EOOD
 * Author: Nikola Lazarov
 *
 * Licensed under the Source-Available Educational License.
 * See the LICENSE file in the project root for full terms.
 */

//! Cloud budgets stored in Google Drive, shared by every Budget Warden app.
//!
//! A cloud budget is mirrored to a local `.budget` file in the app's cache
//! directory. The app opens, edits, and saves that file exactly like a local
//! budget; [`BWGoogleDrive::sync_budget`] then reconciles it with Drive. Sync
//! always CRDT-merges the local copy with the newest remote copy before it
//! uploads, so concurrent edits from several people and devices converge
//! instead of overwriting one another.
//!
//! The host supplies networking ([`BWHttpClient`]) and secure token storage
//! ([`BWGoogleCredentialStore`]). iCloud Drive needs no core support: Apple
//! apps store iCloud budgets as ordinary files in their ubiquity container.

mod drive;
mod google;
pub mod http;
mod oauth;
mod sync;

pub use drive::BUDGET_MIME_TYPE;
pub use google::*;
pub use http::{BWHttpClient, BWHttpHeader, BWHttpRequest, BWHttpResponse};
pub use oauth::{
    BWGoogleSignInRequest, BWOAuthLoopbackReceiver, GOOGLE_DRIVE_SCOPE, is_cloud_sign_in_required,
};

/// Prefix of errors that mean the user must sign in (again). Hosts test for
/// it with [`is_cloud_sign_in_required`].
pub(crate) const AUTH_REQUIRED_PREFIX: &str = "SIGN_IN_REQUIRED: ";

pub(crate) fn auth_required(message: &str) -> String {
    format!("{AUTH_REQUIRED_PREFIX}{message}")
}

#[cfg(test)]
mod tests;
