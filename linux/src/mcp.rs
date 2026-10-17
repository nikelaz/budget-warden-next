//! Linux host for the core MCP server: budget storage, preferences, and the
//! events the server sends back to the GTK main loop.

use std::fs;
use std::path::{Path, PathBuf};
use std::sync::mpsc::{self, Receiver, Sender};
use std::sync::{Arc, Mutex};

use bw_core::codec::decode_budget;
use bw_core::mcp::{
    BWMcpBudgetLocation, BWMcpHost, BWMcpServer, BWMcpServerConfig, BWMcpServerStatus,
    DEFAULT_MCP_PORT, generate_mcp_token,
};

use crate::store::{write_budget_json, write_budget_json_exclusive};

const SETTINGS_FILE: &str = "mcp-server";

/// Persisted MCP server preferences.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct McpSettings {
    pub enabled: bool,
    pub allow_network: bool,
    pub port: i32,
    pub token: String,
}

impl McpSettings {
    pub fn load(settings_dir: &Path) -> Self {
        let mut settings = Self {
            enabled: false,
            allow_network: false,
            port: DEFAULT_MCP_PORT,
            token: String::new(),
        };
        if let Ok(contents) = fs::read_to_string(settings_dir.join(SETTINGS_FILE)) {
            for line in contents.lines() {
                match line.split_once('=') {
                    Some(("enabled", value)) => settings.enabled = value.trim() == "true",
                    Some(("allow_network", value)) => settings.allow_network = value.trim() == "true",
                    Some(("port", value)) => {
                        settings.port = value.trim().parse().unwrap_or(DEFAULT_MCP_PORT)
                    }
                    Some(("token", value)) => settings.token = value.trim().to_string(),
                    _ => (),
                }
            }
        }
        if settings.token.len() < 16 {
            settings.token = generate_mcp_token();
        }
        settings
    }

    pub fn save(&self, settings_dir: &Path) -> Result<(), String> {
        let contents = format!(
            "enabled={}\nallow_network={}\nport={}\ntoken={}\n",
            self.enabled, self.allow_network, self.port, self.token
        );
        fs::write(settings_dir.join(SETTINGS_FILE), contents)
            .map_err(|error| format!("Could not save MCP server preferences: {error}"))
    }
}

/// Work the server asks the UI thread to do.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum McpEvent {
    BudgetChanged(PathBuf),
    BudgetCreated(PathBuf),
    ShowBudget(PathBuf),
}

/// What the server may see of the app, refreshed from the UI thread.
#[derive(Clone, Debug, Default)]
pub struct McpSnapshot {
    pub open_budget: Option<PathBuf>,
    pub recent_files: Vec<PathBuf>,
    pub currency: String,
}

pub struct LinuxMcpHost {
    snapshot: Arc<Mutex<McpSnapshot>>,
    events: Mutex<Sender<McpEvent>>,
    budgets_dir: PathBuf,
}

impl LinuxMcpHost {
    fn known_path(&self, location: &str) -> Result<PathBuf, String> {
        let snapshot = self.snapshot.lock().map_err(|_| "Budget list unavailable.")?;
        let path = PathBuf::from(location);
        let known = snapshot.open_budget.as_ref() == Some(&path)
            || snapshot.recent_files.contains(&path);
        known
            .then_some(path)
            .ok_or_else(|| format!("{location} is not one of Budget Warden's budgets."))
    }

    fn send(&self, event: McpEvent) {
        if let Ok(events) = self.events.lock() {
            let _ = events.send(event);
        }
    }
}

impl BWMcpHost for LinuxMcpHost {
    fn list_budgets(&self) -> Vec<BWMcpBudgetLocation> {
        let Ok(snapshot) = self.snapshot.lock() else {
            return vec![];
        };
        let mut paths: Vec<&PathBuf> = snapshot.open_budget.iter().collect();
        for path in &snapshot.recent_files {
            if !paths.contains(&path) {
                paths.push(path);
            }
        }
        paths
            .into_iter()
            .map(|path| BWMcpBudgetLocation {
                location: path.to_string_lossy().into_owned(),
                is_open: snapshot.open_budget.as_ref() == Some(path),
            })
            .collect()
    }

    fn read_budget_file(&self, location: String) -> Result<String, String> {
        let path = self.known_path(&location)?;
        fs::read_to_string(&path).map_err(|error| format!("Could not read {location}: {error}"))
    }

    fn write_budget_file(&self, location: String, json: String) -> Result<(), String> {
        let path = self.known_path(&location)?;
        decode_budget(&json, location)?;
        write_budget_json(&json, &path)
    }

    fn create_budget_file(&self, file_name: String, json: String) -> Result<String, String> {
        decode_budget(&json, String::new())?;
        fs::create_dir_all(&self.budgets_dir)
            .map_err(|error| format!("Could not create {}: {error}", self.budgets_dir.display()))?;
        let path = unique_path(&self.budgets_dir, &file_name);
        write_budget_json_exclusive(&json, &path)?;
        if let Ok(mut snapshot) = self.snapshot.lock() {
            snapshot.recent_files.insert(0, path.clone());
        }
        self.send(McpEvent::BudgetCreated(path.clone()));
        Ok(path.to_string_lossy().into_owned())
    }

    fn budget_did_change(&self, location: String) {
        self.send(McpEvent::BudgetChanged(PathBuf::from(location)));
    }

    fn show_budget(&self, location: String) -> Result<(), String> {
        let path = self.known_path(&location)?;
        self.send(McpEvent::ShowBudget(path));
        Ok(())
    }

    fn currency_code(&self) -> String {
        self.snapshot
            .lock()
            .map(|snapshot| snapshot.currency.clone())
            .unwrap_or_default()
    }
}

fn unique_path(directory: &Path, file_name: &str) -> PathBuf {
    let candidate = directory.join(file_name);
    if !candidate.exists() {
        return candidate;
    }
    let stem = file_name.strip_suffix(".budget").unwrap_or(file_name);
    (2..)
        .map(|index| directory.join(format!("{stem} {index}.budget")))
        .find(|path| !path.exists())
        .unwrap_or(candidate)
}

/// Owns the server and the channel it reports through.
pub struct McpController {
    settings_dir: PathBuf,
    pub settings: McpSettings,
    server: BWMcpServer,
    snapshot: Arc<Mutex<McpSnapshot>>,
    sender: Sender<McpEvent>,
    receiver: Receiver<McpEvent>,
    budgets_dir: PathBuf,
    pub last_error: Option<String>,
}

impl McpController {
    pub fn new(settings_dir: &Path, budgets_dir: PathBuf) -> Self {
        let (sender, receiver) = mpsc::channel();
        Self {
            settings_dir: settings_dir.to_path_buf(),
            settings: McpSettings::load(settings_dir),
            server: BWMcpServer::new(),
            snapshot: Arc::new(Mutex::new(McpSnapshot::default())),
            sender,
            receiver,
            budgets_dir,
            last_error: None,
        }
    }

    pub fn update_snapshot(&self, snapshot: McpSnapshot) {
        if let Ok(mut current) = self.snapshot.lock() {
            *current = snapshot;
        }
    }

    pub fn status(&self) -> BWMcpServerStatus {
        self.server.status()
    }

    /// Applies the saved settings: starts, restarts, or stops the server.
    pub fn apply(&mut self) {
        self.last_error = None;
        if !self.settings.enabled {
            self.server.stop();
            return;
        }
        let host = LinuxMcpHost {
            snapshot: self.snapshot.clone(),
            events: Mutex::new(self.sender.clone()),
            budgets_dir: self.budgets_dir.clone(),
        };
        let config = BWMcpServerConfig {
            port: self.settings.port,
            token: self.settings.token.clone(),
            allow_network: self.settings.allow_network,
        };
        if let Err(error) = self.server.start(Box::new(host), config) {
            self.last_error = Some(error);
        }
    }

    pub fn update_settings(&mut self, change: impl FnOnce(&mut McpSettings)) {
        change(&mut self.settings);
        if let Err(error) = self.settings.save(&self.settings_dir) {
            eprintln!("{error}");
        }
        self.apply();
    }

    pub fn drain_events(&self) -> Vec<McpEvent> {
        self.receiver.try_iter().collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use bw_core::codec::encode_budget;
    use bw_core::models::BWBudget;
    use uuid::Uuid;

    #[test]
    fn host_limits_access_to_known_budgets_and_reports_events() {
        let _ = bw_core::app_state::initialize_core(Uuid::new_v4());
        let root = std::env::temp_dir().join(format!("bw-linux-mcp-{}", Uuid::new_v4()));
        fs::create_dir_all(&root).unwrap();
        let (sender, receiver) = mpsc::channel();
        let snapshot = Arc::new(Mutex::new(McpSnapshot {
            currency: "BGN".to_string(),
            ..Default::default()
        }));
        let host = LinuxMcpHost {
            snapshot: snapshot.clone(),
            events: Mutex::new(sender),
            budgets_dir: root.join("Budgets"),
        };
        let json = encode_budget(&BWBudget::new("Home".to_string())).unwrap();

        let first = host.create_budget_file("Home.budget".to_string(), json.clone()).unwrap();
        let second = host.create_budget_file("Home.budget".to_string(), json.clone()).unwrap();
        assert!(first.ends_with("Budgets/Home.budget"));
        assert!(second.ends_with("Budgets/Home 2.budget"));
        assert_eq!(host.list_budgets().len(), 2);
        assert_eq!(host.currency_code(), "BGN");

        host.write_budget_file(first.clone(), json.clone()).unwrap();
        assert!(host.read_budget_file(first.clone()).unwrap().contains("Home"));
        assert!(host.read_budget_file("/etc/passwd".to_string()).is_err());
        assert!(host.write_budget_file(first.clone(), "{}".to_string()).is_err());

        host.budget_did_change(first.clone());
        let events: Vec<McpEvent> = receiver.try_iter().collect();
        assert_eq!(events.last(), Some(&McpEvent::BudgetChanged(PathBuf::from(&first))));
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn settings_round_trip_and_always_have_a_token() {
        let root = std::env::temp_dir().join(format!("bw-linux-mcp-settings-{}", Uuid::new_v4()));
        fs::create_dir_all(&root).unwrap();
        let mut settings = McpSettings::load(&root);
        assert!(!settings.enabled);
        assert!(settings.token.len() >= 16);
        settings.enabled = true;
        settings.allow_network = true;
        settings.save(&root).unwrap();
        assert_eq!(McpSettings::load(&root), settings);
        let _ = fs::remove_dir_all(root);
    }
}
