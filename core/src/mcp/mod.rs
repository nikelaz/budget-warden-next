/*
 * Budget Warden
 * Copyright (c) 2026 Lazarov & Co EOOD
 * Author: Nikola Lazarov
 *
 * Licensed under the Source-Available Educational License.
 * See the LICENSE file in the project root for full terms.
 */

//! Model Context Protocol server shared by every Budget Warden app.
//!
//! The server speaks MCP over the Streamable HTTP transport and exposes tools
//! that give an agent the same control over budgets that the apps offer. It
//! owns the protocol, budgeting rules, and CRDT-safe saving; the host app owns
//! storage through [`BWMcpHost`], because each platform reaches `.budget`
//! documents differently (security-scoped URLs, document providers, paths).

mod http;
mod protocol;
mod tools;

use std::net::{SocketAddr, TcpListener, UdpSocket};
use std::sync::{Arc, Mutex};

use boltffi::*;
use uuid::Uuid;

/// Port used when the configuration does not request a specific one.
pub const DEFAULT_MCP_PORT: i32 = 18765;

/// Storage and app integration supplied by the host app.
///
/// Every method is called from a server thread, never from the UI thread, and
/// calls are serialized: at most one method runs at a time.
#[export]
pub trait BWMcpHost: Send + Sync {
    /// Budget documents the app can currently reach, most relevant first.
    fn list_budgets(&self) -> Vec<BWMcpBudgetLocation>;

    /// Reads the raw `.budget` JSON stored at `location`.
    fn read_budget_file(&self, location: String) -> Result<String, String>;

    /// Replaces the `.budget` JSON stored at `location` and returns `true`.
    ///
    /// When `expected_revision_id` is set, the host must check and replace the
    /// document under the same lock its own saves hold for their whole
    /// read-merge-write: if the stored budget's `revision_id` differs, another
    /// writer saved first, so leave the document unchanged and return `false`.
    /// The server then merges with the newer copy and tries again.
    fn write_budget_file(
        &self,
        location: String,
        json: String,
        expected_revision_id: Option<String>,
    ) -> Result<bool, String>;

    /// Stores a new budget document named after `file_name` and returns its
    /// location. The new document should also appear in the app's recent list.
    fn create_budget_file(&self, file_name: String, json: String) -> Result<String, String>;

    /// Tells the app that the server changed the budget at `location`, so an
    /// open copy can be reloaded.
    fn budget_did_change(&self, location: String);

    /// Asks the app to open the budget at `location` in its UI.
    fn show_budget(&self, location: String) -> Result<(), String>;

    /// ISO 4217 code of the currency the app displays amounts in.
    fn currency_code(&self) -> String;
}

/// A budget document reachable by the host.
#[data]
#[derive(Clone, Debug, PartialEq)]
pub struct BWMcpBudgetLocation {
    /// Opaque host identifier for the document (a path or a URI).
    pub location: String,
    /// Whether this budget is the one open in the app.
    pub is_open: bool,
}

#[data]
#[derive(Clone, Debug, PartialEq)]
pub struct BWMcpServerConfig {
    /// TCP port to listen on; `0` selects [`DEFAULT_MCP_PORT`].
    pub port: i32,
    /// Secret path segment that every request must carry.
    pub token: String,
    /// Listen on every network interface instead of loopback only.
    pub allow_network: bool,
}

#[data]
#[derive(Clone, Debug, PartialEq)]
pub struct BWMcpServerStatus {
    pub running: bool,
    pub port: i32,
    /// URL to give MCP clients. On a network listener this uses the device's
    /// LAN address when one can be determined.
    pub url: Option<String>,
    /// URL for clients running on the same device.
    pub local_url: Option<String>,
}

#[export]
pub fn generate_mcp_token() -> String {
    Uuid::new_v4().simple().to_string()
}

#[export]
pub fn default_mcp_server_config() -> BWMcpServerConfig {
    BWMcpServerConfig {
        port: DEFAULT_MCP_PORT,
        token: generate_mcp_token(),
        allow_network: false,
    }
}

struct RunningServer {
    listener: http::Listener,
    status: BWMcpServerStatus,
}

/// A controllable MCP server instance. Apps keep one for their lifetime.
pub struct BWMcpServer {
    running: Mutex<Option<RunningServer>>,
}

impl Default for BWMcpServer {
    fn default() -> Self {
        Self::new()
    }
}

#[export]
impl BWMcpServer {
    pub fn new() -> Self {
        Self {
            running: Mutex::new(None),
        }
    }

    /// Starts listening, replacing a server that is already running.
    pub fn start(
        &self,
        host: Box<dyn BWMcpHost>,
        config: BWMcpServerConfig,
    ) -> Result<BWMcpServerStatus, String> {
        let token = config.token.trim().to_string();
        if token.len() < 16 || !token.chars().all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_') {
            return Err("The MCP server token must be at least 16 letters, digits, '-' or '_'.".to_string());
        }
        let port = match config.port {
            0 => DEFAULT_MCP_PORT,
            port if (1..=65535).contains(&port) => port,
            port => return Err(format!("{port} is not a valid TCP port.")),
        };

        let mut running = self.running.lock().map_err(|_| "The MCP server state is unavailable.".to_string())?;
        if let Some(previous) = running.take() {
            previous.listener.stop();
        }

        let bind_address: SocketAddr = if config.allow_network {
            SocketAddr::from(([0, 0, 0, 0], port as u16))
        } else {
            SocketAddr::from(([127, 0, 0, 1], port as u16))
        };
        let listener = TcpListener::bind(bind_address)
            .map_err(|error| format!("Could not start the MCP server on port {port}: {error}"))?;
        let port = listener
            .local_addr()
            .map(|address| i32::from(address.port()))
            .unwrap_or(port);

        let local_url = format!("http://127.0.0.1:{port}/{token}/mcp");
        let url = if config.allow_network {
            lan_address()
                .map(|address| format!("http://{address}:{port}/{token}/mcp"))
                .unwrap_or_else(|| local_url.clone())
        } else {
            local_url.clone()
        };

        let service = Arc::new(tools::BudgetService::new(Arc::from(host)));
        let listener = http::spawn(listener, token, service)
            .map_err(|error| format!("Could not start the MCP server: {error}"))?;

        let status = BWMcpServerStatus {
            running: true,
            port,
            url: Some(url),
            local_url: Some(local_url),
        };
        *running = Some(RunningServer {
            listener,
            status: status.clone(),
        });
        Ok(status)
    }

    pub fn stop(&self) {
        let previous = self.running.lock().ok().and_then(|mut running| running.take());
        if let Some(previous) = previous {
            previous.listener.stop();
        }
    }

    pub fn status(&self) -> BWMcpServerStatus {
        self.running
            .lock()
            .ok()
            .and_then(|running| running.as_ref().map(|server| server.status.clone()))
            .unwrap_or(BWMcpServerStatus {
                running: false,
                port: 0,
                url: None,
                local_url: None,
            })
    }
}

impl Drop for BWMcpServer {
    fn drop(&mut self) {
        self.stop();
    }
}

/// Best-effort LAN address of this device. Connecting a UDP socket selects the
/// outbound interface without sending any packets.
fn lan_address() -> Option<String> {
    let socket = UdpSocket::bind("0.0.0.0:0").ok()?;
    socket.connect("192.0.2.1:80").ok()?;
    let address = socket.local_addr().ok()?.ip();
    (!address.is_loopback() && !address.is_unspecified()).then(|| address.to_string())
}

#[cfg(test)]
mod tests;
