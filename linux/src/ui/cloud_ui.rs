//! Google Drive presentation: welcome rows, sharing, preferences, and the
//! handling of background cloud results.

use std::path::{Path, PathBuf};
use std::rc::Rc;
use std::time::Duration;

use adw::prelude::*;
use bw_core::cloud::{BWCloudBudget, BWCloudShare, BWCloudShareRole};
use gtk::{Align, Orientation};

use super::{AppUi, action_row, combo_row, entry_row, inline_error};
use crate::cloud::{CloudEvent, budget_subtitle};

const CLOUD_EVENT_POLL_INTERVAL: Duration = Duration::from_millis(250);
/// How often the open cloud budget pulls changes from other people.
const OPEN_BUDGET_SYNC_INTERVAL: Duration = Duration::from_secs(60);
/// How often the list of cloud budgets is refreshed.
const LIST_REFRESH_INTERVAL: Duration = Duration::from_secs(300);

/// The open share dialog, updated as sharing results arrive.
pub(super) struct ShareDialog {
    budget_id: String,
    dialog: gtk::glib::WeakRef<adw::Dialog>,
    people: adw::PreferencesGroup,
    rows: std::cell::RefCell<Vec<gtk::Widget>>,
    email: adw::EntryRow,
    message: adw::EntryRow,
    send: gtk::Button,
    error: gtk::Label,
    can_share: bool,
}

impl AppUi {
    pub(super) fn watch_cloud(self: &Rc<Self>) {
        let weak = Rc::downgrade(self);
        gtk::glib::timeout_add_local(CLOUD_EVENT_POLL_INTERVAL, move || {
            let Some(ui) = weak.upgrade() else {
                return gtk::glib::ControlFlow::Break;
            };
            let events = ui.cloud.borrow_mut().drain_events();
            for event in events {
                ui.handle_cloud_event(event);
            }
            gtk::glib::ControlFlow::Continue
        });
        let weak = Rc::downgrade(self);
        gtk::glib::timeout_add_local(OPEN_BUDGET_SYNC_INTERVAL, move || {
            let Some(ui) = weak.upgrade() else {
                return gtk::glib::ControlFlow::Break;
            };
            ui.sync_open_cloud_budget();
            gtk::glib::ControlFlow::Continue
        });
        let weak = Rc::downgrade(self);
        gtk::glib::timeout_add_local(LIST_REFRESH_INTERVAL, move || {
            let Some(ui) = weak.upgrade() else {
                return gtk::glib::ControlFlow::Break;
            };
            ui.cloud.borrow_mut().refresh();
            gtk::glib::ControlFlow::Continue
        });
        self.cloud.borrow_mut().refresh();
    }

    /// Drive file ID of the open budget, when it is a cloud budget.
    pub(super) fn open_cloud_id(&self) -> Option<String> {
        let path = self.state.borrow().budget.as_ref()?.url.clone()?;
        self.cloud.borrow().budget_id_for_path(Path::new(&path))
    }

    pub(super) fn sync_open_cloud_budget(&self) {
        if let Some(id) = self.open_cloud_id() {
            self.cloud.borrow().sync(id);
        }
    }

    pub(super) fn open_cloud_budget(self: &Rc<Self>, id: String) {
        self.cloud.borrow().open(id);
    }

    fn handle_cloud_event(self: &Rc<Self>, event: CloudEvent) {
        match event {
            CloudEvent::Listed(_) | CloudEvent::SignedOut => self.refresh_cloud_lists(),
            CloudEvent::SignedIn(Ok(_)) => {
                self.cloud.borrow_mut().refresh();
                self.refresh_cloud_lists();
            }
            CloudEvent::Added(Ok(budgets)) => {
                self.refresh_cloud_lists();
                if let [budget] = budgets.as_slice() {
                    self.open_cloud_budget(budget.id.clone());
                }
            }
            CloudEvent::Added(Err(error)) => {
                self.refresh_cloud_lists();
                self.show_error(&error);
            }
            CloudEvent::SignedIn(Err(error)) => {
                self.refresh_cloud_lists();
                if error != "Google sign-in was cancelled." {
                    self.show_error(&error);
                }
            }
            CloudEvent::Opened(Ok(result)) => self.open_budget(PathBuf::from(result.local_path)),
            CloudEvent::Created(Ok(budget)) => {
                self.refresh_cloud_lists();
                if let Some(path) = budget.local_path {
                    self.open_budget(PathBuf::from(path));
                }
            }
            CloudEvent::Opened(Err(error)) | CloudEvent::Created(Err(error)) => {
                self.show_error(&error)
            }
            CloudEvent::Synced(Ok(result)) => {
                let is_open = self
                    .state
                    .borrow()
                    .budget
                    .as_ref()
                    .and_then(|budget| budget.url.as_deref())
                    .is_some_and(|url| Path::new(url) == Path::new(&result.local_path));
                if result.local_changed && is_open {
                    let reloaded = self.state.borrow_mut().reload_budget();
                    match reloaded {
                        Ok(()) => self.refresh(),
                        Err(error) => self.show_error(&error),
                    }
                }
            }
            CloudEvent::Synced(Err(error)) => {
                // Sync retries on the next save or timer; only a lost sign-in
                // needs the user.
                eprintln!("Cloud sync failed: {error}");
                let mut cloud = self.cloud.borrow_mut();
                cloud.last_error = Some(error);
                if !cloud.is_signed_in() {
                    drop(cloud);
                    self.refresh_cloud_lists();
                }
            }
            CloudEvent::Shared(id, result) => {
                let dialog = self.share_dialog.borrow();
                let Some(dialog) = dialog.as_ref().filter(|dialog| dialog.budget_id == id) else {
                    return;
                };
                dialog.send.set_sensitive(true);
                match result {
                    Ok(_) => {
                        dialog.email.set_text("");
                        dialog.message.set_text("");
                        dialog.error.set_visible(false);
                        self.cloud.borrow().load_shares(id);
                    }
                    Err(error) => inline_error(&dialog.error, &error),
                }
            }
            CloudEvent::Shares(id, result) => self.show_shares(&id, result),
            CloudEvent::ShareRemoved(id, result) => {
                if let Err(error) = result
                    && let Some(dialog) = self.share_dialog.borrow().as_ref()
                {
                    inline_error(&dialog.error, &error);
                }
                self.cloud.borrow().load_shares(id);
            }
        }
    }

    /// Re-renders the places that list cloud budgets.
    fn refresh_cloud_lists(self: &Rc<Self>) {
        if self.state.borrow().budget.is_none() {
            self.refresh();
        } else if let Some(main) = self.main.borrow().as_ref() {
            main.recent.set_menu_model(Some(&self.recent_menu()));
        }
    }

    /// The Google Drive section of the welcome screen.
    pub(super) fn cloud_welcome_group(self: &Rc<Self>) -> Option<adw::PreferencesGroup> {
        let cloud = self.cloud.borrow();
        if !cloud.is_configured() {
            return None;
        }
        let group = adw::PreferencesGroup::builder()
            .title("Google Drive")
            .build();
        if !cloud.is_signed_in() {
            group.set_description(Some(
                "Keep budgets in Google Drive to use them on every device and share them with others.",
            ));
            let row = action_row(
                "Connect Google Drive",
                if cloud.is_signing_in() {
                    "Continue in your browser…"
                } else {
                    "Sign in with your Google account"
                },
            );
            let button = gtk::Button::builder()
                .label(if cloud.is_signing_in() {
                    "Cancel"
                } else {
                    "Sign In"
                })
                .valign(Align::Center)
                .build();
            let ui = self.clone();
            button.connect_clicked(move |_| ui.toggle_cloud_sign_in());
            row.add_suffix(&button);
            group.add(&row);
            return Some(group);
        }

        let refresh = gtk::Button::builder()
            .icon_name("view-refresh-symbolic")
            .tooltip_text("Refresh")
            .valign(Align::Center)
            .css_classes(["flat"])
            .sensitive(!cloud.refreshing)
            .build();
        let ui = self.clone();
        refresh.connect_clicked(move |_| {
            ui.cloud.borrow_mut().refresh();
            ui.refresh();
        });
        group.set_header_suffix(Some(&refresh));
        if let Some(email) = cloud.account().and_then(|account| account.email) {
            group.set_description(Some(&email));
        }
        if let Some(error) = &cloud.last_error {
            let row = action_row("Could not reach Google Drive", error);
            row.add_prefix(&gtk::Image::from_icon_name("dialog-warning-symbolic"));
            group.add(&row);
        }
        let budgets = cloud.budgets.clone();
        drop(cloud);
        if budgets.is_empty() {
            group.add(&action_row(
                "No cloud budgets yet",
                "Create a budget in Google Drive, or add one someone shared with you.",
            ));
        }
        let (shared, mine): (Vec<_>, Vec<_>) = budgets
            .into_iter()
            .partition(|budget| budget.shared_with_me);
        for budget in mine.into_iter().chain(shared) {
            group.add(&self.cloud_budget_row(&budget));
        }
        if self.cloud.borrow().can_add_shared() {
            let adding = self.cloud.borrow().is_adding_shared();
            let row = action_row(
                "Add Shared Budget…",
                if adding {
                    "Choose the budget in your browser…"
                } else {
                    "Choose a budget someone shared with you in Google Drive"
                },
            );
            row.add_prefix(&gtk::Image::from_icon_name("list-add-symbolic"));
            let button = gtk::Button::builder()
                .label(if adding { "Cancel" } else { "Choose" })
                .valign(Align::Center)
                .build();
            let ui = self.clone();
            button.connect_clicked(move |_| {
                {
                    let mut cloud = ui.cloud.borrow_mut();
                    if cloud.is_adding_shared() {
                        cloud.cancel_add_shared();
                    } else {
                        cloud.add_shared();
                    }
                }
                ui.refresh_cloud_lists();
            });
            row.add_suffix(&button);
            group.add(&row);
        }
        Some(group)
    }

    fn cloud_budget_row(self: &Rc<Self>, budget: &BWCloudBudget) -> adw::ActionRow {
        let row = action_row(&budget.title, &budget_subtitle(budget));
        row.set_activatable(true);
        row.add_prefix(&gtk::Image::from_icon_name(if budget.shared_with_me {
            "system-users-symbolic"
        } else {
            "folder-remote-symbolic"
        }));
        if budget.can_share {
            let share = gtk::Button::builder()
                .icon_name("send-to-symbolic")
                .tooltip_text("Share")
                .valign(Align::Center)
                .css_classes(["flat"])
                .build();
            let ui = self.clone();
            let id = budget.id.clone();
            share.connect_clicked(move |_| ui.show_share_dialog(id.clone()));
            row.add_suffix(&share);
        }
        row.add_suffix(&gtk::Image::from_icon_name("go-next-symbolic"));
        let ui = self.clone();
        let id = budget.id.clone();
        row.connect_activated(move |_| ui.open_cloud_budget(id.clone()));
        row
    }

    fn toggle_cloud_sign_in(self: &Rc<Self>) {
        {
            let mut cloud = self.cloud.borrow_mut();
            if cloud.is_signing_in() {
                cloud.cancel_sign_in();
            } else {
                cloud.sign_in();
            }
        }
        self.refresh_cloud_lists();
    }

    /// The Google Drive section of Preferences.
    pub(super) fn cloud_preferences_group(self: &Rc<Self>) -> adw::PreferencesGroup {
        let group = adw::PreferencesGroup::builder()
            .title("Google Drive")
            .description("Budgets in Google Drive sync between your devices and the people you share them with.")
            .build();
        let cloud = self.cloud.borrow();
        if !cloud.is_configured() {
            group.add(&action_row(
                "Not available",
                "This build of Budget Warden has no Google Drive client ID.",
            ));
            return group;
        }
        let signed_in = cloud.is_signed_in();
        let account = cloud
            .account()
            .and_then(|account| account.email.or(account.display_name));
        drop(cloud);
        let row = action_row(
            "Account",
            &account.unwrap_or_else(|| {
                if signed_in {
                    "Signed in".into()
                } else {
                    "Not signed in".into()
                }
            }),
        );
        let button = gtk::Button::builder()
            .label(if signed_in { "Sign Out" } else { "Sign In" })
            .valign(Align::Center)
            .build();
        if signed_in {
            button.add_css_class("destructive-action");
        }
        let ui = self.clone();
        let weak_row = row.downgrade();
        button.connect_clicked(move |button| {
            if ui.cloud.borrow().is_signed_in() {
                ui.cloud.borrow_mut().sign_out();
                if let Some(row) = weak_row.upgrade() {
                    row.set_subtitle("Not signed in");
                }
                button.set_label("Sign In");
                button.remove_css_class("destructive-action");
            } else {
                ui.toggle_cloud_sign_in();
                if let Some(row) = weak_row.upgrade() {
                    row.set_subtitle("Continue in your browser…");
                }
            }
        });
        row.add_suffix(&button);
        group.add(&row);
        group
    }

    /// Uploads the open local budget as a new cloud budget.
    pub(super) fn upload_open_budget(self: &Rc<Self>) {
        let Some(path) = self
            .state
            .borrow()
            .budget
            .as_ref()
            .and_then(|budget| budget.url.clone())
        else {
            return;
        };
        let path = PathBuf::from(path);
        match std::fs::read_to_string(&path) {
            Ok(json) => {
                let name = path
                    .file_name()
                    .map(|name| name.to_string_lossy().into_owned())
                    .unwrap_or_else(|| "Budget.budget".to_string());
                self.cloud.borrow().create(name, json);
            }
            Err(error) => self.show_error(&format!("Could not read the budget: {error}")),
        }
    }

    pub(super) fn show_share_dialog(self: &Rc<Self>, id: String) {
        let Some(budget) = self.cloud.borrow().budget(&id).cloned() else {
            return;
        };
        let dialog = adw::Dialog::builder()
            .title(format!("Share “{}”", budget.title))
            .content_width(480)
            .build();
        let toolbar = adw::ToolbarView::new();
        toolbar.add_top_bar(&adw::HeaderBar::new());
        let body = gtk::Box::new(Orientation::Vertical, 18);
        body.set_margin_top(18);
        body.set_margin_bottom(24);
        body.set_margin_start(24);
        body.set_margin_end(24);

        let error = gtk::Label::new(None);
        error.set_wrap(true);
        error.set_xalign(0.0);
        error.add_css_class("error");
        error.set_visible(false);
        body.append(&error);

        let invite = adw::PreferencesGroup::builder()
            .title("Invite")
            .description("They receive an email from Google, and Budget Warden lists the budget for them under budgets shared with them.")
            .build();
        let email = entry_row("Email address", "");
        email.set_input_purpose(gtk::InputPurpose::Email);
        let role = combo_row("Permission", &["Can edit", "Can view"]);
        let message = entry_row("Message (optional)", "");
        let send = gtk::Button::builder()
            .label("Send Invite")
            .halign(Align::End)
            .css_classes(["suggested-action", "pill"])
            .sensitive(false)
            .build();
        let weak_send = send.downgrade();
        email.connect_changed(move |entry| {
            if let Some(send) = weak_send.upgrade() {
                send.set_sensitive(entry.text().contains('@'));
            }
        });
        invite.add(&email);
        invite.add(&role);
        invite.add(&message);
        if budget.can_share {
            body.append(&invite);
            body.append(&send);
        }

        let people = adw::PreferencesGroup::builder()
            .title("People With Access")
            .build();
        let loading = action_row("Loading…", "");
        people.add(&loading);
        body.append(&people);

        let scroll = gtk::ScrolledWindow::builder()
            .hscrollbar_policy(gtk::PolicyType::Never)
            .propagate_natural_height(true)
            .child(&body)
            .build();
        toolbar.set_content(Some(&scroll));
        dialog.set_child(Some(&toolbar));

        let ui = self.clone();
        let budget_id = id.clone();
        let (email_entry, role_row, message_entry) = (email.clone(), role.clone(), message.clone());
        send.connect_clicked(move |send| {
            let role = if role_row.selected() == 1 {
                BWCloudShareRole::Reader
            } else {
                BWCloudShareRole::Writer
            };
            let note = message_entry.text().trim().to_string();
            send.set_sensitive(false);
            ui.cloud.borrow().share(
                budget_id.clone(),
                email_entry.text().to_string(),
                role,
                (!note.is_empty()).then_some(note),
            );
        });
        let ui = self.clone();
        dialog.connect_closed(move |_| {
            ui.share_dialog.replace(None);
        });

        *self.share_dialog.borrow_mut() = Some(ShareDialog {
            budget_id: id.clone(),
            dialog: dialog.downgrade(),
            people,
            rows: std::cell::RefCell::new(vec![loading.upcast()]),
            email,
            message,
            send,
            error,
            can_share: budget.can_share,
        });
        self.cloud.borrow().load_shares(id);
        dialog.present(Some(&self.window));
    }

    fn show_shares(self: &Rc<Self>, id: &str, result: Result<Vec<BWCloudShare>, String>) {
        let dialog = self.share_dialog.borrow();
        let Some(dialog) = dialog.as_ref().filter(|dialog| dialog.budget_id == id) else {
            return;
        };
        if dialog.dialog.upgrade().is_none() {
            return;
        }
        for row in dialog.rows.borrow_mut().drain(..) {
            dialog.people.remove(&row);
        }
        let shares = match result {
            Ok(shares) => shares,
            Err(error) => {
                inline_error(&dialog.error, &error);
                return;
            }
        };
        for share in shares {
            let title = share
                .display_name
                .clone()
                .or_else(|| share.email.clone())
                .unwrap_or_else(|| match share.kind.as_str() {
                    "anyone" => "Anyone with the link".to_string(),
                    "domain" => "Everyone in the organization".to_string(),
                    _ => "Unknown".to_string(),
                });
            let role = match share.role {
                BWCloudShareRole::Owner => "Owner",
                BWCloudShareRole::Writer => "Can edit",
                BWCloudShareRole::Commenter => "Can comment",
                BWCloudShareRole::Reader => "Can view",
            };
            let subtitle = match (&share.display_name, &share.email) {
                (Some(_), Some(email)) => format!("{email} · {role}"),
                _ => role.to_string(),
            };
            let row = action_row(&title, &subtitle);
            if dialog.can_share && share.role != BWCloudShareRole::Owner {
                let remove = gtk::Button::builder()
                    .icon_name("user-trash-symbolic")
                    .tooltip_text("Remove access")
                    .valign(Align::Center)
                    .css_classes(["flat"])
                    .build();
                let ui = self.clone();
                let (budget_id, share_id) = (id.to_string(), share.id.clone());
                remove.connect_clicked(move |button| {
                    button.set_sensitive(false);
                    ui.cloud
                        .borrow()
                        .remove_share(budget_id.clone(), share_id.clone());
                });
                row.add_suffix(&remove);
            }
            dialog.people.add(&row);
            dialog.rows.borrow_mut().push(row.upcast());
        }
    }
}
