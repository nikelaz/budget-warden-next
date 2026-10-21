//! Google Drive budgets for the Linux app.
//!
//! Every network call runs on a worker thread; results come back as
//! [`CloudEvent`]s that the GTK main loop drains, like MCP server events.

use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::sync::mpsc::{self, Receiver, Sender};
use std::sync::{Arc, Mutex};

use bw_core::cloud::native::{
    FileCredentialStore, NativeHttpClient, desktop_google_config, open_in_browser,
};
use bw_core::cloud::{
    BWCloudBudget, BWCloudShare, BWCloudShareRole, BWCloudSyncResult, BWGoogleAccount,
    BWGoogleDrive, BWGoogleLoopbackReceiver, cloud_error_message,
};

/// How long the browser sign-in may take.
const SIGN_IN_TIMEOUT_SECONDS: i32 = 300;

/// Results of background cloud work, delivered to the UI thread.
#[derive(Debug)]
pub enum CloudEvent {
    Listed(Result<Vec<BWCloudBudget>, String>),
    SignedIn(Result<BWGoogleAccount, String>),
    /// Budgets the user chose in the shared-budget picker.
    Added(Result<Vec<BWCloudBudget>, String>),
    SignedOut,
    Opened(Result<BWCloudSyncResult, String>),
    Synced(Result<BWCloudSyncResult, String>),
    Created(Result<BWCloudBudget, String>),
    Shared(String, Result<BWCloudShare, String>),
    Shares(String, Result<Vec<BWCloudShare>, String>),
    ShareRemoved(String, Result<(), String>),
}

/// Opens a URL in the user's browser.
pub type UrlOpener = Arc<dyn Fn(&str) -> Result<(), String> + Send + Sync>;

pub struct CloudController {
    drive: Arc<BWGoogleDrive>,
    open_url: UrlOpener,
    sender: Sender<CloudEvent>,
    receiver: Receiver<CloudEvent>,
    /// Budgets from the latest listing, or the cache before the first one.
    pub budgets: Vec<BWCloudBudget>,
    /// A listing is in flight.
    pub refreshing: bool,
    /// The latest listing or sync error, for the welcome screen.
    pub last_error: Option<String>,
    sign_in: Option<Arc<BWGoogleLoopbackReceiver>>,
    picking: Option<Arc<BWGoogleLoopbackReceiver>>,
    syncing: Arc<Mutex<HashSet<String>>>,
    sync_again: Arc<Mutex<HashSet<String>>>,
}

impl CloudController {
    /// Stores credentials and working copies in `settings_dir`.
    pub fn new(settings_dir: &Path) -> Self {
        let drive = BWGoogleDrive::new(desktop_google_config(&settings_dir.join("cloud")));
        drive.connect(
            Box::new(NativeHttpClient::new()),
            Box::new(FileCredentialStore::new(
                settings_dir.join("google-credentials.json"),
            )),
        );
        Self::with_drive(Arc::new(drive))
    }

    pub fn with_drive(drive: Arc<BWGoogleDrive>) -> Self {
        Self::with_drive_and_browser(drive, Arc::new(open_in_browser))
    }

    /// Uses `open_url` instead of the system browser, for tests.
    pub fn with_drive_and_browser(drive: Arc<BWGoogleDrive>, open_url: UrlOpener) -> Self {
        let (sender, receiver) = mpsc::channel();
        Self {
            open_url,
            budgets: drive.cached_budgets(),
            drive,
            sender,
            receiver,
            refreshing: false,
            last_error: None,
            sign_in: None,
            picking: None,
            syncing: Arc::default(),
            sync_again: Arc::default(),
        }
    }

    pub fn is_configured(&self) -> bool {
        self.drive.is_configured()
    }

    pub fn is_signed_in(&self) -> bool {
        self.drive.is_signed_in()
    }

    pub fn is_signing_in(&self) -> bool {
        self.sign_in.is_some()
    }

    /// Whether this build can add budgets others shared with the user.
    pub fn can_add_shared(&self) -> bool {
        self.drive.is_picker_configured()
    }

    pub fn is_adding_shared(&self) -> bool {
        self.picking.is_some()
    }

    pub fn account(&self) -> Option<BWGoogleAccount> {
        self.drive.account()
    }

    /// Whether `path` is the working copy of a cloud budget.
    pub fn is_cloud_path(&self, path: &Path) -> bool {
        self.drive
            .is_cloud_path(path.to_string_lossy().into_owned())
    }

    pub fn budget_id_for_path(&self, path: &Path) -> Option<String> {
        self.drive
            .budget_id_for_path(path.to_string_lossy().into_owned())
    }

    pub fn budget(&self, id: &str) -> Option<&BWCloudBudget> {
        self.budgets.iter().find(|budget| budget.id == id)
    }

    pub fn drain_events(&mut self) -> Vec<CloudEvent> {
        let events: Vec<_> = self.receiver.try_iter().collect();
        for event in &events {
            match event {
                CloudEvent::Listed(result) => {
                    self.refreshing = false;
                    match result {
                        Ok(budgets) => {
                            self.budgets = budgets.clone();
                            self.last_error = None;
                        }
                        Err(error) => self.last_error = Some(cloud_error_message(error.clone())),
                    }
                }
                CloudEvent::SignedIn(_) => self.sign_in = None,
                CloudEvent::Added(result) => {
                    self.picking = None;
                    if let Ok(budgets) = result {
                        for budget in budgets {
                            self.remember(budget.clone());
                        }
                    }
                }
                CloudEvent::SignedOut => {
                    self.budgets.clear();
                    self.last_error = None;
                }
                CloudEvent::Opened(Ok(result)) | CloudEvent::Synced(Ok(result)) => {
                    self.remember(result.budget.clone())
                }
                CloudEvent::Created(Ok(budget)) => self.remember(budget.clone()),
                _ => (),
            }
        }
        events
    }

    fn remember(&mut self, budget: BWCloudBudget) {
        match self.budgets.iter_mut().find(|known| known.id == budget.id) {
            Some(known) => *known = budget,
            None => self.budgets.insert(0, budget),
        }
    }

    fn spawn(&self, work: impl FnOnce(&BWGoogleDrive) -> CloudEvent + Send + 'static) {
        let drive = self.drive.clone();
        let sender = self.sender.clone();
        let spawned = std::thread::Builder::new()
            .name("bw-cloud".to_string())
            .spawn(move || {
                let _ = sender.send(work(&drive));
            });
        if let Err(error) = spawned {
            eprintln!("Could not start cloud work: {error}");
        }
    }

    pub fn refresh(&mut self) {
        if self.refreshing || !self.is_signed_in() {
            return;
        }
        self.refreshing = true;
        self.spawn(|drive| CloudEvent::Listed(drive.list_budgets()));
    }

    /// Opens the browser for Google sign-in and waits for it in the
    /// background.
    pub fn sign_in(&mut self) {
        if self.sign_in.is_some() {
            return;
        }
        let receiver = Arc::new(BWGoogleLoopbackReceiver::new());
        self.sign_in = Some(receiver.clone());
        let open_url = self.open_url.clone();
        self.spawn(move |drive| {
            let result = (|| {
                let redirect = receiver.start()?;
                let request = drive.begin_sign_in(redirect)?;
                open_url(&request.authorization_url)?;
                let callback = receiver.wait_for_redirect(SIGN_IN_TIMEOUT_SECONDS)?;
                drive.complete_sign_in(callback)
            })();
            CloudEvent::SignedIn(result.map_err(cloud_error_message))
        });
    }

    /// Opens the shared-budget picker in the browser. Budget Warden only
    /// reaches Google Drive files it created or that the user chooses there.
    pub fn add_shared(&mut self) {
        if self.picking.is_some() {
            return;
        }
        let receiver = Arc::new(BWGoogleLoopbackReceiver::new());
        self.picking = Some(receiver.clone());
        let open_url = self.open_url.clone();
        self.spawn(move |drive| {
            let result = (|| {
                let redirect = receiver.start()?;
                let url = drive.shared_budget_picker_url(Some(format!("{redirect}/picked")))?;
                open_url(&url)?;
                let callback = receiver.wait_for_redirect(SIGN_IN_TIMEOUT_SECONDS)?;
                drive.add_picked_budgets(callback)
            })();
            CloudEvent::Added(result.map_err(cloud_error_message))
        });
    }

    pub fn cancel_add_shared(&mut self) {
        if let Some(receiver) = self.picking.take() {
            receiver.cancel();
        }
    }

    pub fn cancel_sign_in(&mut self) {
        if let Some(receiver) = self.sign_in.take() {
            receiver.cancel();
        }
    }

    pub fn sign_out(&mut self) {
        self.budgets.clear();
        self.spawn(|drive| {
            drive.sign_out();
            CloudEvent::SignedOut
        });
    }

    pub fn open(&self, id: String) {
        self.spawn(move |drive| {
            CloudEvent::Opened(drive.open_budget(id).map_err(cloud_error_message))
        });
    }

    /// Syncs a budget. Requests that arrive while it is already syncing run
    /// once more afterwards, so the latest save always reaches Drive.
    pub fn sync(&self, id: String) {
        {
            let mut syncing = self
                .syncing
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            if !syncing.insert(id.clone()) {
                self.sync_again
                    .lock()
                    .unwrap_or_else(|poisoned| poisoned.into_inner())
                    .insert(id);
                return;
            }
        }
        let drive = self.drive.clone();
        let sender = self.sender.clone();
        let syncing = self.syncing.clone();
        let sync_again = self.sync_again.clone();
        let spawned = std::thread::Builder::new()
            .name("bw-cloud-sync".to_string())
            .spawn(move || {
                loop {
                    let result = drive.sync_budget(id.clone()).map_err(cloud_error_message);
                    let _ = sender.send(CloudEvent::Synced(result));
                    let mut syncing = syncing
                        .lock()
                        .unwrap_or_else(|poisoned| poisoned.into_inner());
                    let again = sync_again
                        .lock()
                        .unwrap_or_else(|poisoned| poisoned.into_inner())
                        .remove(&id);
                    if !again {
                        syncing.remove(&id);
                        break;
                    }
                }
            });
        if spawned.is_err() {
            self.syncing
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner())
                .clear();
        }
    }

    /// Uploads an encoded budget as a new cloud budget.
    pub fn create(&self, file_name: String, json: String) {
        self.spawn(move |drive| {
            CloudEvent::Created(
                drive
                    .create_budget(file_name, json)
                    .map_err(cloud_error_message),
            )
        });
    }

    pub fn share(
        &self,
        id: String,
        email: String,
        role: BWCloudShareRole,
        message: Option<String>,
    ) {
        self.spawn(move |drive| {
            let result = drive
                .share_budget(id.clone(), email, role, message)
                .map_err(cloud_error_message);
            CloudEvent::Shared(id, result)
        });
    }

    pub fn load_shares(&self, id: String) {
        self.spawn(move |drive| {
            let result = drive.list_shares(id.clone()).map_err(cloud_error_message);
            CloudEvent::Shares(id, result)
        });
    }

    pub fn remove_share(&self, id: String, share_id: String) {
        self.spawn(move |drive| {
            let result = drive
                .remove_share(id.clone(), share_id)
                .map_err(cloud_error_message);
            CloudEvent::ShareRemoved(id, result)
        });
    }

    /// Local recent files that are not cloud working copies.
    pub fn local_files(&self, recent: &[PathBuf]) -> Vec<PathBuf> {
        recent
            .iter()
            .filter(|path| !self.is_cloud_path(path))
            .cloned()
            .collect()
    }
}

/// A short description of who owns or shares a cloud budget.
pub fn budget_subtitle(budget: &BWCloudBudget) -> String {
    let who = budget
        .owner_name
        .clone()
        .or_else(|| budget.owner_email.clone())
        .unwrap_or_else(|| "someone".to_string());
    match (budget.shared_with_me, budget.can_edit, budget.is_shared) {
        (true, true, _) => format!("Shared by {who}"),
        (true, false, _) => format!("Shared by {who} · View only"),
        (false, _, true) => "Google Drive · Shared".to_string(),
        (false, _, false) => "Google Drive".to_string(),
    }
}
