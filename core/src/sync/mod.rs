//! Cloud sync building blocks: wire protocol types and client-side encryption.
//!
//! Compiled only with the `cloud-sync` feature. The server validates the same
//! envelope shape without decrypting it.

pub mod crypto;
pub mod protocol;
