use std::fs::{self, File, OpenOptions};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::thread;
use std::time::{Duration, Instant};

use fs2::FileExt;
use uuid::Uuid;

use crate::error::{ApiError, io_error, missing_file};
use bw_core::models::BWBudget;

pub const LOCK_TIMEOUT: Duration = Duration::from_secs(5);

pub struct BudgetLock {
    _file: File,
}

impl Drop for BudgetLock {
    fn drop(&mut self) {
        let _ = FileExt::unlock(&self._file);
    }
}

#[derive(Clone)]
pub struct LoadedBudget {
    pub path: PathBuf,
    pub budget: BWBudget,
    pub requires_migration_writeback: bool,
}

pub fn absolute_path(path: &Path) -> Result<PathBuf, ApiError> {
    let path = if path.is_absolute() {
        path.to_path_buf()
    } else {
        std::env::current_dir()
            .map_err(|error| io_error(error, "."))?
            .join(path)
    };
    let parent = path.parent().unwrap_or_else(|| Path::new("."));
    let name = path
        .file_name()
        .ok_or_else(|| ApiError::new("invalid_path", "A file name is required", 2))?;
    let parent =
        fs::canonicalize(parent).map_err(|error| io_error(error, parent.display().to_string()))?;
    Ok(parent.join(name))
}

pub fn reject_symlink(path: &Path) -> Result<(), ApiError> {
    match fs::symlink_metadata(path) {
        Ok(metadata) if metadata.file_type().is_symlink() => Err(ApiError::new(
            "symlink_not_supported",
            "Budget writes through symbolic links are not supported",
            6,
        )
        .details(serde_json::json!({"path": path.display().to_string()}))),
        Ok(_) => Ok(()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(io_error(error, path.display().to_string())),
    }
}

fn sidecar_path(path: &Path) -> PathBuf {
    let mut name = path.file_name().unwrap_or_default().to_os_string();
    name.push(".budget-warden.lock");
    path.with_file_name(name)
}

pub fn lock(path: &Path) -> Result<BudgetLock, ApiError> {
    let path = absolute_path(path)?;
    let parent = path.parent().unwrap_or_else(|| Path::new("."));
    fs::create_dir_all(parent).map_err(|error| io_error(error, parent.display().to_string()))?;
    let sidecar = sidecar_path(&path);
    reject_symlink(&sidecar)?;
    let file = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .open(&sidecar)
        .map_err(|error| io_error(error, sidecar.display().to_string()))?;
    let start = Instant::now();
    loop {
        match file.try_lock_exclusive() {
            Ok(()) => return Ok(BudgetLock { _file: file }),
            Err(error) if error.kind() == std::io::ErrorKind::WouldBlock && start.elapsed() < LOCK_TIMEOUT => thread::sleep(Duration::from_millis(40)),
            Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => return Err(ApiError::new("lock_timeout", "Timed out waiting for the budget lock", 5)
                .retryable(true).details(serde_json::json!({"path": path.display().to_string(), "timeout_ms": LOCK_TIMEOUT.as_millis()}))),
            Err(error) => return Err(io_error(error, sidecar.display().to_string())),
        }
    }
}

pub fn load(path: &Path) -> Result<LoadedBudget, ApiError> {
    let resolved = absolute_path(path)?;
    let mut file = File::open(&resolved).map_err(|error| {
        if error.kind() == std::io::ErrorKind::NotFound {
            missing_file(resolved.display().to_string())
        } else {
            io_error(error, resolved.display().to_string())
        }
    })?;
    let mut json = String::new();
    file.read_to_string(&mut json)
        .map_err(|error| io_error(error, resolved.display().to_string()))?;
    let mut budget = bw_core::codec::decode_budget(&json, resolved.display().to_string()).map_err(
        |message| {
            ApiError::new("decode_failed", message, 4)
                .details(serde_json::json!({"path": resolved.display().to_string()}))
        },
    )?;
    // Core migration creates a provisional revision on every decode. Use the
    // persisted legacy token until writeback so conditional CLI operations can
    // compare repeated reads of the same snapshot.
    if budget.requires_migration_writeback {
        let value: serde_json::Value = serde_json::from_str(&json)
            .map_err(|error| ApiError::new("decode_failed", error.to_string(), 4))?;
        if let Some(revision) = value.get("revisionId").and_then(|value| value.as_str()) {
            budget.revision_id = Uuid::parse_str(revision)
                .map_err(|error| ApiError::new("decode_failed", error.to_string(), 4))?;
        }
    }
    let requires_migration_writeback = budget.requires_migration_writeback;
    Ok(LoadedBudget {
        path: resolved,
        budget,
        requires_migration_writeback,
    })
}

pub fn write_new(
    path: &Path,
    budget: &BWBudget,
    overwrite_budget_id: Option<Uuid>,
) -> Result<(), ApiError> {
    let path = absolute_path(path)?;
    reject_symlink(&path)?;
    let _lock = lock(&path)?;
    if path.exists() {
        let existing = load(&path)?;
        if overwrite_budget_id != Some(existing.budget.id) {
            return Err(ApiError::new("destination_exists", "Destination already exists; provide its budget ID to replace it", 6)
                .details(serde_json::json!({"path": path.display().to_string(), "budget_id": existing.budget.id})).outcome("not_written"));
        }
        atomic_replace(&path, budget)?;
    } else {
        atomic_create(&path, budget)?;
    }
    Ok(())
}

pub fn write_new_bytes(
    path: &Path,
    bytes: &[u8],
    budget_id: Uuid,
    overwrite_budget_id: Option<Uuid>,
) -> Result<(), ApiError> {
    let path = absolute_path(path)?;
    reject_symlink(&path)?;
    let _lock = lock(&path)?;
    if path.exists() {
        let existing = load(&path)?;
        if overwrite_budget_id != Some(existing.budget.id) {
            return Err(ApiError::new("destination_exists", "Destination already exists; provide its budget ID to replace it", 6)
                .details(serde_json::json!({"path": path.display().to_string(), "budget_id": existing.budget.id})).outcome("not_written"));
        }
        atomic_replace_bytes(&path, bytes, budget_id)?;
    } else {
        atomic_create_bytes(&path, bytes, budget_id)?;
    }
    Ok(())
}

pub fn create_bytes_locked(
    path: &Path,
    bytes: &[u8],
    budget_id: Uuid,
    overwrite_budget_id: Option<Uuid>,
) -> Result<(), ApiError> {
    let path = absolute_path(path)?;
    reject_symlink(&path)?;
    if path.exists() {
        let existing = load(&path)?;
        if overwrite_budget_id != Some(existing.budget.id) {
            return Err(ApiError::new("destination_exists", "Destination already exists; provide its budget ID to replace it", 6)
                .details(serde_json::json!({"path": path.display().to_string(), "budget_id": existing.budget.id})).outcome("not_written"));
        }
        atomic_replace_bytes(&path, bytes, budget_id)?;
    } else {
        atomic_create_bytes(&path, bytes, budget_id)?;
    }
    Ok(())
}

pub fn replace_bytes(path: &Path, bytes: &[u8], budget_id: Uuid) -> Result<(), ApiError> {
    atomic_replace_bytes(path, bytes, budget_id)
}

pub fn sync_directory(path: &Path) -> std::io::Result<()> {
    sync_parent(path)
}

pub fn commit_mutation(
    path: &Path,
    expected_revision: Option<Uuid>,
    original_revision: Uuid,
    mutated: BWBudget,
) -> Result<BWBudget, ApiError> {
    let path = absolute_path(path)?;
    reject_symlink(&path)?;
    let latest = load(&path)?;
    if let Some(expected) = expected_revision {
        if latest.budget.revision_id != expected || expected != original_revision {
            return Err(ApiError::new("revision_conflict", "Budget revision changed before commit", 5)
                .retryable(true).details(serde_json::json!({"expected_revision_id": expected, "actual_revision_id": latest.budget.revision_id}))
                .outcome("not_written"));
        }
    }
    let result = bw_core::domain::merge_budget_for_save(mutated, latest.budget.clone())
        .map_err(|message| ApiError::new("merge_failed", message, 4).outcome("not_written"))?
        .update_actuals()
        .map_err(|message| ApiError::new("validation_failed", message, 4).outcome("not_written"))?;
    let encoded = bw_core::codec::encode_budget(&result)
        .map_err(|message| ApiError::new("encode_failed", message, 4).outcome("not_written"))?;
    atomic_replace_bytes(&path, encoded.as_bytes(), result.id)?;
    Ok(result)
}

pub fn preview_mutation(original: &BWBudget, mutated: BWBudget) -> Result<BWBudget, ApiError> {
    let result = bw_core::domain::merge_budget_for_save(mutated, original.clone())
        .map_err(|message| ApiError::new("merge_failed", message, 4))?
        .update_actuals()
        .map_err(|message| ApiError::new("validation_failed", message, 4))?;
    bw_core::codec::encode_budget(&result)
        .map_err(|message| ApiError::new("validation_failed", message, 4))?;
    Ok(result)
}

pub fn atomic_create(path: &Path, budget: &BWBudget) -> Result<(), ApiError> {
    let encoded = bw_core::codec::encode_budget(budget)
        .map_err(|message| ApiError::new("encode_failed", message, 4).outcome("not_written"))?;
    atomic_create_bytes(path, encoded.as_bytes(), budget.id)
}

fn atomic_create_bytes(path: &Path, bytes: &[u8], budget_id: Uuid) -> Result<(), ApiError> {
    let parent = path.parent().unwrap_or_else(|| Path::new("."));
    fs::create_dir_all(parent)
        .map_err(|error| io_error(error, parent.display().to_string()).outcome("not_written"))?;
    let (mut temp, temp_path) = staged_file(parent, bytes)?;
    if let Err(error) = temp.flush().and_then(|_| temp.sync_all()) {
        drop(temp);
        let _ = fs::remove_file(&temp_path);
        return Err(io_error(error, temp_path.display().to_string()).outcome("not_written"));
    }
    drop(temp);
    match create_noclobber(&temp_path, path) {
        Ok(()) => {
            if let Err(error) = fs::remove_file(&temp_path) {
                if error.kind() != std::io::ErrorKind::NotFound {
                    return Err(io_error(error, temp_path.display().to_string()).outcome("written"));
                }
            }
            sync_parent(parent).map_err(|error| {
                io_error(error, parent.display().to_string()).outcome("written")
            })?;
            Ok(())
        }
        Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {
            let _ = fs::remove_file(&temp_path);
            Err(ApiError::new("destination_exists", "Destination already exists", 6).details(serde_json::json!({"path": path.display().to_string(), "budget_id": budget_id})).outcome("not_written"))
        }
        Err(error) => {
            let _ = fs::remove_file(&temp_path);
            Err(io_error(error, path.display().to_string()).outcome("not_written"))
        }
    }
}

#[cfg(not(windows))]
fn create_noclobber(source: &Path, destination: &Path) -> std::io::Result<()> {
    fs::hard_link(source, destination)
}

#[cfg(windows)]
fn create_noclobber(source: &Path, destination: &Path) -> std::io::Result<()> {
    use std::os::windows::ffi::OsStrExt;
    const MOVEFILE_WRITE_THROUGH: u32 = 0x8;
    #[link(name = "Kernel32")]
    unsafe extern "system" {
        fn MoveFileExW(existing: *const u16, new: *const u16, flags: u32) -> i32;
    }
    let source: Vec<u16> = source.as_os_str().encode_wide().chain(Some(0)).collect();
    let destination: Vec<u16> = destination
        .as_os_str()
        .encode_wide()
        .chain(Some(0))
        .collect();
    // Without REPLACE_EXISTING, the move is atomic and fails if the destination exists.
    // SAFETY: both pointers refer to null-terminated buffers valid for this call.
    let result = unsafe {
        MoveFileExW(
            source.as_ptr(),
            destination.as_ptr(),
            MOVEFILE_WRITE_THROUGH,
        )
    };
    if result == 0 {
        Err(std::io::Error::last_os_error())
    } else {
        Ok(())
    }
}

fn atomic_replace(path: &Path, budget: &BWBudget) -> Result<(), ApiError> {
    let encoded = bw_core::codec::encode_budget(budget)
        .map_err(|message| ApiError::new("encode_failed", message, 4).outcome("not_written"))?;
    atomic_replace_bytes(path, encoded.as_bytes(), budget.id)
}

fn atomic_replace_bytes(path: &Path, bytes: &[u8], _budget_id: Uuid) -> Result<(), ApiError> {
    reject_symlink(path)?;
    let parent = path.parent().unwrap_or_else(|| Path::new("."));
    fs::create_dir_all(parent)
        .map_err(|error| io_error(error, parent.display().to_string()).outcome("not_written"))?;
    let permissions = fs::metadata(path)
        .ok()
        .map(|metadata| metadata.permissions());
    let (mut temp, temp_path) = staged_file(parent, bytes)?;
    if let Some(permissions) = permissions {
        if let Err(error) = fs::set_permissions(&temp_path, permissions) {
            drop(temp);
            let _ = fs::remove_file(&temp_path);
            return Err(io_error(error, temp_path.display().to_string()).outcome("not_written"));
        }
    }
    if let Err(error) = temp.flush().and_then(|_| temp.sync_all()) {
        drop(temp);
        let _ = fs::remove_file(&temp_path);
        return Err(io_error(error, temp_path.display().to_string()).outcome("not_written"));
    }
    drop(temp);
    if let Err(error) = replace_file(&temp_path, path) {
        let _ = fs::remove_file(&temp_path);
        return Err(io_error(error, path.display().to_string()).outcome("unknown"));
    }
    sync_parent(parent)
        .map_err(|error| io_error(error, parent.display().to_string()).outcome("written"))?;
    Ok(())
}

fn staged_file(parent: &Path, bytes: &[u8]) -> Result<(File, PathBuf), ApiError> {
    for _ in 0..8 {
        let path = parent.join(format!(".budget-warden-{}.tmp", Uuid::new_v4()));
        let mut options = OpenOptions::new();
        options.write(true).read(true).create_new(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        match options.open(&path) {
            Ok(mut file) => {
                if let Err(error) = file.write_all(bytes) {
                    drop(file);
                    let _ = fs::remove_file(&path);
                    return Err(io_error(error, path.display().to_string()).outcome("not_written"));
                }
                return Ok((file, path));
            }
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(error) => {
                return Err(io_error(error, path.display().to_string()).outcome("not_written"));
            }
        }
    }
    Err(
        ApiError::new("io_error", "Could not allocate a temporary budget file", 6)
            .outcome("not_written"),
    )
}

#[cfg(not(windows))]
fn replace_file(source: &Path, destination: &Path) -> std::io::Result<()> {
    fs::rename(source, destination)
}

#[cfg(windows)]
fn replace_file(source: &Path, destination: &Path) -> std::io::Result<()> {
    use std::os::windows::ffi::OsStrExt;
    const MOVEFILE_REPLACE_EXISTING: u32 = 0x1;
    const MOVEFILE_WRITE_THROUGH: u32 = 0x8;
    #[link(name = "Kernel32")]
    unsafe extern "system" {
        fn MoveFileExW(existing: *const u16, new: *const u16, flags: u32) -> i32;
    }
    let source: Vec<u16> = source.as_os_str().encode_wide().chain(Some(0)).collect();
    let destination: Vec<u16> = destination
        .as_os_str()
        .encode_wide()
        .chain(Some(0))
        .collect();
    // SAFETY: both pointers refer to null-terminated buffers valid for this call.
    let result = unsafe {
        MoveFileExW(
            source.as_ptr(),
            destination.as_ptr(),
            MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH,
        )
    };
    if result == 0 {
        Err(std::io::Error::last_os_error())
    } else {
        Ok(())
    }
}

#[cfg(unix)]
fn sync_parent(parent: &Path) -> std::io::Result<()> {
    File::open(parent)?.sync_all()
}
#[cfg(windows)]
fn sync_parent(_parent: &Path) -> std::io::Result<()> {
    Ok(())
}

pub fn remove_budget(
    path: &Path,
    expected_id: Uuid,
    expected_revision: Option<Uuid>,
) -> Result<BWBudget, ApiError> {
    let path = absolute_path(path)?;
    reject_symlink(&path)?;
    let _lock = lock(&path)?;
    let loaded = load(&path)?;
    if loaded.budget.id != expected_id {
        return Err(ApiError::new("budget_id_mismatch", "Confirmation ID does not match this budget", 2)
            .details(serde_json::json!({"expected_budget_id": expected_id, "actual_budget_id": loaded.budget.id})).outcome("not_written"));
    }
    if let Some(expected) = expected_revision {
        if loaded.budget.revision_id != expected {
            return Err(ApiError::new("revision_conflict", "Budget revision changed before deletion", 5).retryable(true)
                .details(serde_json::json!({"expected_revision_id": expected, "actual_revision_id": loaded.budget.revision_id})).outcome("not_written"));
        }
    }
    fs::remove_file(&path)
        .map_err(|error| io_error(error, path.display().to_string()).outcome("not_written"))?;
    if let Some(parent) = path.parent() {
        sync_parent(parent)
            .map_err(|error| io_error(error, parent.display().to_string()).outcome("written"))?;
    }
    Ok(loaded.budget)
}

pub fn list_budget_files(directory: &Path) -> Result<Vec<PathBuf>, ApiError> {
    let mut files = Vec::new();
    for entry in
        fs::read_dir(directory).map_err(|error| io_error(error, directory.display().to_string()))?
    {
        let entry = entry.map_err(|error| io_error(error, directory.display().to_string()))?;
        if entry
            .file_type()
            .map_err(|error| io_error(error, entry.path().display().to_string()))?
            .is_file()
            && entry
                .path()
                .extension()
                .is_some_and(|extension| extension == "budget")
        {
            files.push(entry.path());
        }
    }
    files.sort_by(|left, right| left.to_string_lossy().cmp(&right.to_string_lossy()));
    Ok(files)
}
