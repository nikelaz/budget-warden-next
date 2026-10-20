/*
 * Budget Warden
 * Copyright (c) 2026 Lazarov & Co EOOD
 * Author: Nikola Lazarov
 *
 * Licensed under the Source-Available Educational License.
 * See the LICENSE file in the project root for full terms.
 */

//! Local mirror of cloud budgets and the CRDT reconciliation behind sync.
//!
//! Layout under `<cache directory>/google-drive/`:
//!
//! ```text
//! state.json               folder ID and per-file metadata
//! <file id>/<name>.budget  the working copy the app opens and saves
//! <file id>/remote.json    the newest remote content this device has seen
//! ```

use std::collections::BTreeMap;
use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use serde_json::Value;
use uuid::Uuid;

use super::drive::DriveFile;
use crate::crdt;
use crate::models::BWBudget;

const PROVIDER_DIRECTORY: &str = "google-drive";
const STATE_FILE: &str = "state.json";
const SNAPSHOT_FILE: &str = "remote.json";

#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq)]
pub(crate) struct CacheState {
    #[serde(default)]
    pub folder_id: Option<String>,
    #[serde(default)]
    pub files: BTreeMap<String, CachedFile>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub(crate) struct CachedFile {
    pub file: DriveFile,
    /// File name of the working copy inside the file's directory.
    pub local_name: String,
    /// Drive `version` of the content in `remote.json`.
    #[serde(default)]
    pub snapshot_version: Option<String>,
}

pub(crate) struct Cache {
    root: PathBuf,
}

impl Cache {
    pub fn new(cache_directory: &str) -> Self {
        Self {
            root: Path::new(cache_directory).join(PROVIDER_DIRECTORY),
        }
    }

    pub fn root(&self) -> &Path {
        &self.root
    }

    pub fn load_state(&self) -> CacheState {
        fs::read_to_string(self.root.join(STATE_FILE))
            .ok()
            .and_then(|json| serde_json::from_str(&json).ok())
            .unwrap_or_default()
    }

    pub fn save_state(&self, state: &CacheState) -> Result<(), String> {
        let json = serde_json::to_string_pretty(state)
            .map_err(|error| format!("Could not record cloud budgets: {error}"))?;
        write_atomically(&self.root.join(STATE_FILE), &json)
    }

    pub fn file_directory(&self, file_id: &str) -> PathBuf {
        // Drive IDs are [A-Za-z0-9_-]; anything else is replaced so an ID can
        // never escape the cache directory.
        let safe: String = file_id
            .chars()
            .map(|c| if c.is_ascii_alphanumeric() || c == '-' || c == '_' { c } else { '_' })
            .collect();
        self.root.join(safe)
    }

    pub fn working_copy(&self, file_id: &str, local_name: &str) -> PathBuf {
        self.file_directory(file_id).join(local_name)
    }

    pub fn snapshot(&self, file_id: &str) -> PathBuf {
        self.file_directory(file_id).join(SNAPSHOT_FILE)
    }

    /// The Drive file ID whose working copy is `path`, if any.
    pub fn file_id_for_path(&self, state: &CacheState, path: &Path) -> Option<String> {
        let path = normalize(path);
        state.files.iter().find_map(|(id, cached)| {
            (normalize(&self.working_copy(id, &cached.local_name)) == path).then(|| id.clone())
        })
    }

    pub fn remove(&self, file_id: &str) {
        let _ = fs::remove_dir_all(self.file_directory(file_id));
    }

    pub fn clear(&self) {
        let _ = fs::remove_dir_all(&self.root);
    }
}

fn normalize(path: &Path) -> PathBuf {
    fs::canonicalize(path).unwrap_or_else(|_| path.to_path_buf())
}

/// A file name for the working copy of a Drive file called `name`.
pub(crate) fn local_file_name(name: &str) -> String {
    let stem = name.strip_suffix(".budget").unwrap_or(name);
    let cleaned: String = stem
        .chars()
        .map(|c| match c {
            '/' | '\\' | ':' | '*' | '?' | '"' | '<' | '>' | '|' => '-',
            c if c.is_control() => '-',
            c => c,
        })
        .take(120)
        .collect();
    let cleaned = cleaned.trim().trim_start_matches('.').trim();
    let stem = if cleaned.is_empty() { "Budget" } else { cleaned };
    format!("{stem}.budget")
}

/// Writes `contents` to `path` through a temporary file and a rename, so a
/// reader never sees a partial budget.
pub(crate) fn write_atomically(path: &Path, contents: &str) -> Result<(), String> {
    let parent = path
        .parent()
        .ok_or_else(|| "The cloud cache path has no parent folder.".to_string())?;
    fs::create_dir_all(parent).map_err(|error| format!("Could not create the cloud cache: {error}"))?;
    let name = path.file_name().and_then(|name| name.to_str()).unwrap_or("file");
    let temporary = parent.join(format!(".{name}.{}.tmp", Uuid::new_v4().simple()));
    let result = (|| {
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&temporary)
            .map_err(|error| format!("Could not write the cloud cache: {error}"))?;
        file.write_all(contents.as_bytes())
            .and_then(|_| file.sync_all())
            .map_err(|error| format!("Could not write the cloud cache: {error}"))?;
        fs::rename(&temporary, path).map_err(|error| format!("Could not write the cloud cache: {error}"))
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    result
}

/// Budget content without the per-save revision identity, for deciding
/// whether two copies differ in anything a person would notice.
pub(crate) fn content(budget: &BWBudget) -> Value {
    let mut value = serde_json::to_value(budget).unwrap_or(Value::Null);
    if let Some(object) = value.as_object_mut() {
        object.remove("revision");
        object.remove("revision_id");
    }
    value
}

pub(crate) struct Reconciliation {
    pub merged: BWBudget,
    /// The working copy lacks something the merge contains.
    pub local_changed: bool,
    /// The remote copy lacks something the merge contains.
    pub remote_changed: bool,
}

/// Merges the working copy with the newest remote copy.
pub(crate) fn reconcile(local: BWBudget, remote: BWBudget) -> Result<Reconciliation, String> {
    if local.id != remote.id {
        return Err("The Google Drive file now holds a different budget. Remove it from this device and open it again.".to_string());
    }
    let local_content = content(&local);
    let remote_content = content(&remote);
    if local_content == remote_content {
        return Ok(Reconciliation {
            merged: local,
            local_changed: false,
            remote_changed: false,
        });
    }
    let url = local.url.clone();
    let mut merged = crdt::merge(local, remote).update_actuals()?;
    merged.url = url;
    let merged_content = content(&merged);
    Ok(Reconciliation {
        local_changed: merged_content != local_content,
        remote_changed: merged_content != remote_content,
        merged,
    })
}
