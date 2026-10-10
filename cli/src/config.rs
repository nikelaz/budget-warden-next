use std::env;
use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::error::{ApiError, io_error};

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ConfigFile {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub device_id: Option<Uuid>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub currency: Option<String>,
    #[serde(default)]
    pub recent_files: Vec<PathBuf>,
}

pub fn config_dir(override_dir: Option<&Path>) -> PathBuf {
    if let Some(path) = override_dir {
        return path.to_path_buf();
    }
    if let Some(path) = env::var_os("BUDGET_WARDEN_CONFIG_DIR") {
        return PathBuf::from(path);
    }
    if cfg!(target_os = "windows") {
        env::var_os("APPDATA")
            .or_else(|| env::var_os("LOCALAPPDATA"))
            .map(PathBuf::from)
            .unwrap_or_else(|| env::current_dir().unwrap_or_else(|_| PathBuf::from(".")))
            .join("Budget Warden")
    } else if cfg!(target_os = "macos") {
        env::var_os("HOME")
            .map(PathBuf::from)
            .unwrap_or_else(|| PathBuf::from("."))
            .join("Library/Application Support/Budget Warden")
    } else {
        env::var_os("XDG_CONFIG_HOME")
            .map(PathBuf::from)
            .or_else(|| env::var_os("HOME").map(|home| PathBuf::from(home).join(".config")))
            .unwrap_or_else(|| PathBuf::from("."))
            .join("budget-warden")
    }
}

pub fn config_path(override_dir: Option<&Path>) -> PathBuf {
    config_dir(override_dir).join("config.json")
}

pub fn load(override_dir: Option<&Path>) -> Result<ConfigFile, ApiError> {
    let path = config_path(override_dir);
    match fs::read(&path) {
        Ok(bytes) => serde_json::from_slice(&bytes).map_err(|error| {
            ApiError::new(
                "config_invalid",
                format!("Could not parse CLI settings: {error}"),
                4,
            )
            .details(serde_json::json!({"path": path}))
        }),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(ConfigFile::default()),
        Err(error) => Err(io_error(error, path.display().to_string())),
    }
}

pub fn save(override_dir: Option<&Path>, config: &ConfigFile) -> Result<(), ApiError> {
    let directory = config_dir(override_dir);
    fs::create_dir_all(&directory)
        .map_err(|error| io_error(error, directory.display().to_string()))?;
    let target = directory.join("config.json");
    crate::storage::reject_symlink(&target)?;
    let _lock = crate::storage::lock(&target)?;
    save_unlocked(&directory, config)
}

pub fn update<T>(
    override_dir: Option<&Path>,
    update: impl FnOnce(&mut ConfigFile) -> Result<T, ApiError>,
) -> Result<T, ApiError> {
    let directory = config_dir(override_dir);
    fs::create_dir_all(&directory)
        .map_err(|error| io_error(error, directory.display().to_string()))?;
    let target = directory.join("config.json");
    crate::storage::reject_symlink(&target)?;
    let _lock = crate::storage::lock(&target)?;
    let mut config = load(override_dir)?;
    let value = update(&mut config)?;
    save_unlocked(&directory, &config)?;
    Ok(value)
}

fn save_unlocked(directory: &Path, config: &ConfigFile) -> Result<(), ApiError> {
    let target = directory.join("config.json");
    crate::storage::reject_symlink(&target)?;
    let bytes = serde_json::to_vec_pretty(config)
        .map_err(|error| ApiError::new("internal_error", error.to_string(), 1))?;
    let temporary = directory.join(format!(".config-{}.tmp", Uuid::new_v4()));
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&temporary)
        .map_err(|error| io_error(error, temporary.display().to_string()))?;
    if let Err(error) = file.write_all(&bytes).and_then(|_| file.sync_all()) {
        drop(file);
        let _ = fs::remove_file(&temporary);
        return Err(io_error(error, temporary.display().to_string()));
    }
    drop(file);
    replace_config(&temporary, &target).map_err(|error| {
        let _ = fs::remove_file(&temporary);
        io_error(error, target.display().to_string())
    })?;
    if let Ok(directory_file) = OpenOptions::new().read(true).open(&directory) {
        let _ = directory_file.sync_all();
    }
    Ok(())
}

pub fn device_id(
    override_dir: Option<&Path>,
    override_id: Option<Uuid>,
    persist: bool,
) -> Result<Uuid, ApiError> {
    if let Some(id) = override_id {
        return Ok(id);
    }
    if !persist {
        return Ok(load(override_dir)?.device_id.unwrap_or_else(Uuid::new_v4));
    }
    let directory = config_dir(override_dir);
    fs::create_dir_all(&directory)
        .map_err(|error| io_error(error, directory.display().to_string()))?;
    let path = directory.join("config.json");
    let _lock = crate::storage::lock(&path)?;
    let mut config = load(override_dir)?;
    if let Some(id) = config.device_id {
        return Ok(id);
    }
    let id = Uuid::new_v4();
    config.device_id = Some(id);
    save_unlocked(&directory, &config)?;
    Ok(id)
}

#[cfg(not(windows))]
fn replace_config(source: &Path, destination: &Path) -> std::io::Result<()> {
    fs::rename(source, destination)
}

#[cfg(windows)]
fn replace_config(source: &Path, destination: &Path) -> std::io::Result<()> {
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
