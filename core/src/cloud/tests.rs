//! End-to-end tests of Google Drive budgets against an in-memory Drive.

use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use uuid::Uuid;

use super::drive::BUDGET_MIME_TYPE;
use super::oauth::REVOCATION_ENDPOINT;
use super::testing::{FakeDrive, MemoryCredentials};
use super::*;
use crate::app_state::initialize_core;
use crate::codec::{decode_budget, encode_budget};
use crate::domain;
use crate::models::{BWBudget, BWCategory, BWCategoryType, BWDate, BWMoneyAmount, BWTransaction};
use crate::templates::budget_from_template_id;

// MARK: Helpers

struct Device {
    drive: BWGoogleDrive,
    credentials: MemoryCredentials,
    directory: PathBuf,
}

impl Drop for Device {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.directory);
    }
}

fn device(server: &FakeDrive) -> Device {
    let _ = initialize_core(Uuid::from_u128(0xC10D));
    let directory = std::env::temp_dir().join(format!("bw-cloud-test-{}", Uuid::new_v4().simple()));
    let drive = BWGoogleDrive::new(BWGoogleDriveConfig {
        client_id: "test-client".into(),
        client_secret: Some("secret".into()),
        cache_directory: directory.to_string_lossy().into_owned(),
        folder_name: "Budget Warden".into(),
        picker_url: Some("https://example.com/pick".into()),
    });
    let credentials = MemoryCredentials::default();
    drive.connect(Box::new(server.clone()), Box::new(credentials.clone()));
    Device {
        drive,
        credentials,
        directory,
    }
}

fn signed_in(server: &FakeDrive, email: &str) -> Device {
    let device = device(server);
    let request = device
        .drive
        .begin_sign_in("http://127.0.0.1:4567".into())
        .unwrap();
    let callback = server.approve(&request.authorization_url, email);
    let account = device.drive.complete_sign_in(callback).unwrap();
    assert_eq!(account.email.as_deref(), Some(email));
    device
}

fn new_budget_json(title: &str) -> String {
    encode_budget(&budget_from_template_id("basic-monthly".into(), title.into()).unwrap()).unwrap()
}

fn read_budget(path: &str) -> BWBudget {
    decode_budget(&std::fs::read_to_string(path).unwrap(), path.to_string()).unwrap()
}

/// Edits a working copy the way the apps save: merge with disk, then write.
fn app_edit(path: &str, edit: impl FnOnce(BWBudget) -> BWBudget) {
    let on_disk = read_budget(path);
    let edited = edit(on_disk.clone()).update_actuals().unwrap();
    let merged = domain::merge_budget_for_save(edited, on_disk).unwrap();
    std::fs::write(path, encode_budget(&merged).unwrap()).unwrap();
}

fn add_transaction(budget: BWBudget, title: &str, cents: i64) -> BWBudget {
    let category = budget
        .categories
        .iter()
        .find(|category| category.category_type == BWCategoryType::Expenses)
        .unwrap()
        .id;
    domain::create_transaction(
        budget,
        category,
        BWTransaction {
            id: Uuid::new_v4(),
            title: title.into(),
            description: String::new(),
            date: BWDate {
                year: 2026,
                month: 10,
                day: 20,
            },
            amount: BWMoneyAmount { value: cents },
        },
    )
    .unwrap()
}

fn add_category(budget: BWBudget, title: &str) -> BWBudget {
    let ordinal = budget.categories.len() as i32;
    domain::create_category(
        budget,
        BWCategory {
            id: Uuid::new_v4(),
            ordinal,
            title: title.into(),
            amount_planned: BWMoneyAmount { value: 1000 },
            amount_actual: BWMoneyAmount { value: 0 },
            amount_accumulated: BWMoneyAmount { value: 0 },
            category_type: BWCategoryType::Expenses,
            transactions: vec![],
        },
    )
    .unwrap()
}

fn transaction_titles(budget: &BWBudget) -> Vec<String> {
    let mut titles: Vec<String> = budget
        .categories
        .iter()
        .flat_map(|category| category.transactions.iter().map(|tx| tx.title.clone()))
        .collect();
    titles.sort();
    titles
}

fn has_category(budget: &BWBudget, title: &str) -> bool {
    budget
        .categories
        .iter()
        .any(|category| category.title == title)
}

// MARK: Tests

#[test]
fn sign_in_uses_pkce_and_stores_a_refresh_token() {
    let server = FakeDrive::default();
    let device = signed_in(&server, "ana@example.com");
    assert!(device.drive.is_signed_in());
    assert_eq!(
        device.drive.account().unwrap().email.as_deref(),
        Some("ana@example.com")
    );
    let stored = device.credentials.load_credentials().unwrap();
    assert!(stored.contains("rt-ana@example.com"));

    // A tampered state is rejected and leaves no pending sign-in behind.
    let other = device_with_pending(&server);
    assert!(
        other
            .drive
            .complete_sign_in("http://127.0.0.1:4567/?state=wrong&code=x".into())
            .is_err()
    );
    assert!(
        other
            .drive
            .complete_sign_in("http://127.0.0.1:4567/?state=wrong&code=x".into())
            .is_err()
    );
    assert!(!other.drive.is_signed_in());
}

fn device_with_pending(server: &FakeDrive) -> Device {
    let device = device(server);
    device
        .drive
        .begin_sign_in("http://127.0.0.1:4567".into())
        .unwrap();
    device
}

#[test]
fn unconfigured_builds_and_signed_out_calls_explain_themselves() {
    let server = FakeDrive::default();
    let device = device(&server);
    let unconfigured = BWGoogleDrive::new(BWGoogleDriveConfig {
        client_id: " ".into(),
        client_secret: None,
        cache_directory: device.directory.to_string_lossy().into_owned(),
        folder_name: "Budget Warden".into(),
        picker_url: Some("https://example.com/pick".into()),
    });
    assert!(!unconfigured.is_configured());
    assert!(
        unconfigured
            .begin_sign_in("http://127.0.0.1:1".into())
            .is_err()
    );

    let error = device.drive.list_budgets().unwrap_err();
    assert!(is_cloud_sign_in_required(error.clone()));
    assert_eq!(
        cloud_error_message(error),
        "Sign in to Google Drive to sync your budgets."
    );
}

#[test]
fn created_budgets_live_in_the_app_folder_and_open_from_a_working_copy() {
    let server = FakeDrive::default();
    let device = signed_in(&server, "ana@example.com");

    let created = device
        .drive
        .create_budget("October".into(), new_budget_json("October"))
        .unwrap();
    let second = device
        .drive
        .create_budget("Nov/ember.budget".into(), new_budget_json("November"))
        .unwrap();
    assert_eq!(created.name, "October.budget");
    assert_eq!(second.name, "Nov-ember.budget");
    assert!(!created.shared_with_me && created.can_edit && created.can_share);

    let file = server.file(&created.id);
    assert_eq!(file.mime_type, BUDGET_MIME_TYPE);
    assert_eq!(file.app_properties["budgetWarden"], "budget");
    let folder = server.file(&file.parents[0]);
    assert_eq!(folder.name, "Budget Warden");
    assert_eq!(
        server.file(&second.id).parents,
        file.parents,
        "the folder is created once"
    );

    let path = created.local_path.clone().unwrap();
    assert!(device.drive.is_cloud_path(path.clone()));
    assert_eq!(
        device.drive.budget_id_for_path(path.clone()),
        Some(created.id.clone())
    );
    assert_eq!(read_budget(&path).title, "October");
    assert!(
        !device.drive.is_cloud_path(
            device
                .directory
                .join("elsewhere.budget")
                .to_string_lossy()
                .into_owned()
        )
    );

    let listed = device.drive.list_budgets().unwrap();
    assert_eq!(listed.len(), 2);
    assert_eq!(device.drive.cached_budgets(), listed);
}

#[test]
fn concurrent_edits_on_two_devices_converge() {
    let server = FakeDrive::default();
    let laptop = signed_in(&server, "ana@example.com");
    let phone = signed_in(&server, "ana@example.com");

    let created = laptop
        .drive
        .create_budget("Shared".into(), new_budget_json("Shared"))
        .unwrap();
    let laptop_path = created.local_path.unwrap();
    let opened = phone.drive.open_budget(created.id.clone()).unwrap();
    assert!(opened.local_changed && !opened.remote_changed);
    let phone_path = opened.local_path;

    app_edit(&laptop_path, |budget| {
        add_transaction(budget, "Coffee", 450)
    });
    app_edit(&phone_path, |budget| add_category(budget, "Gym"));
    app_edit(&phone_path, |budget| add_transaction(budget, "Bus", 280));

    let laptop_sync = laptop.drive.sync_budget(created.id.clone()).unwrap();
    assert!(laptop_sync.remote_changed && !laptop_sync.local_changed);
    let phone_sync = phone.drive.sync_budget(created.id.clone()).unwrap();
    assert!(phone_sync.remote_changed && phone_sync.local_changed);
    let laptop_sync = laptop.drive.sync_budget(created.id.clone()).unwrap();
    assert!(laptop_sync.local_changed && !laptop_sync.remote_changed);

    for path in [&laptop_path, &phone_path] {
        let budget = read_budget(path);
        assert_eq!(transaction_titles(&budget), vec!["Bus", "Coffee"]);
        assert!(has_category(&budget, "Gym"));
    }
    let remote = decode_budget(&server.file(&created.id).content, String::new()).unwrap();
    assert_eq!(transaction_titles(&remote), vec!["Bus", "Coffee"]);

    // Once converged, syncing neither uploads nor downloads.
    let (downloads, uploads) = server.counts();
    for device in [&laptop, &phone] {
        let result = device.drive.sync_budget(created.id.clone()).unwrap();
        assert!(!result.local_changed && !result.remote_changed);
    }
    assert_eq!(server.counts(), (downloads, uploads));
}

#[test]
fn a_lost_upload_race_heals_on_the_next_sync() {
    let server = FakeDrive::default();
    let first = signed_in(&server, "ana@example.com");
    let second = signed_in(&server, "ana@example.com");
    let created = first
        .drive
        .create_budget("Race".into(), new_budget_json("Race"))
        .unwrap();
    let first_path = created.local_path.unwrap();
    let second_path = second
        .drive
        .open_budget(created.id.clone())
        .unwrap()
        .local_path;

    app_edit(&second_path, |budget| {
        add_transaction(budget, "Second", 100)
    });
    second.drive.sync_budget(created.id.clone()).unwrap();

    // Another writer replaces Drive content with a stale copy, as a
    // last-writer-wins race would.
    let stale = std::fs::read_to_string(
        first
            .directory
            .join("google-drive")
            .join(&created.id)
            .join("remote.json"),
    )
    .unwrap();
    {
        let mut state = server.state.lock().unwrap();
        let file = state.files.get_mut(&created.id).unwrap();
        file.content = stale;
        file.version += 1;
    }
    app_edit(&first_path, |budget| add_transaction(budget, "First", 200));
    first.drive.sync_budget(created.id.clone()).unwrap();
    // The second device still holds its edit and pushes it again.
    let result = second.drive.sync_budget(created.id.clone()).unwrap();
    assert!(result.remote_changed && result.local_changed);
    first.drive.sync_budget(created.id.clone()).unwrap();
    assert_eq!(
        transaction_titles(&read_budget(&first_path)),
        vec!["First", "Second"]
    );
}

#[test]
fn shared_budgets_are_added_through_the_picker_and_editable_by_writers_only() {
    let server = FakeDrive::default();
    let owner = signed_in(&server, "ana@example.com");
    let writer = signed_in(&server, "ben@example.com");
    let reader = signed_in(&server, "cy@example.com");

    let created = owner
        .drive
        .create_budget("Family".into(), new_budget_json("Family"))
        .unwrap();
    assert!(writer.drive.list_budgets().unwrap().is_empty());

    let share = owner
        .drive
        .share_budget(
            created.id.clone(),
            " ben@example.com ".into(),
            BWCloudShareRole::Writer,
            Some("Our budget".into()),
        )
        .unwrap();
    assert_eq!(share.role, BWCloudShareRole::Writer);
    owner
        .drive
        .share_budget(
            created.id.clone(),
            "cy@example.com".into(),
            BWCloudShareRole::Reader,
            None,
        )
        .unwrap();
    assert!(
        owner
            .drive
            .share_budget(
                created.id.clone(),
                "not an email".into(),
                BWCloudShareRole::Reader,
                None
            )
            .is_err()
    );
    assert_eq!(
        server.state.lock().unwrap().notifications,
        vec!["ben@example.com", "cy@example.com"]
    );

    let shares = owner.drive.list_shares(created.id.clone()).unwrap();
    assert_eq!(
        shares.iter().map(|s| s.role).collect::<Vec<_>>(),
        vec![
            BWCloudShareRole::Owner,
            BWCloudShareRole::Writer,
            BWCloudShareRole::Reader
        ]
    );
    assert!(owner.drive.list_budgets().unwrap()[0].is_shared);

    // Invitations link to the picker with the budget preselected.
    let messages = server.state.lock().unwrap().invitation_messages.clone();
    assert_eq!(
        messages[0],
        format!(
            "Our budget\n\nOpen it in Budget Warden: https://example.com/pick?file={}",
            created.id
        )
    );
    assert_eq!(
        messages[1],
        format!(
            "Open it in Budget Warden: https://example.com/pick?file={}",
            created.id
        )
    );

    // drive.file only reaches budgets the recipient picked for the app.
    assert!(writer.drive.list_budgets().unwrap().is_empty());
    assert!(writer.drive.open_budget(created.id.clone()).is_err());
    let picker = writer
        .drive
        .shared_budget_picker_url(Some("http://127.0.0.1:5000".into()))
        .unwrap();
    assert_eq!(
        picker,
        "https://example.com/pick?return_to=http%3A%2F%2F127.0.0.1%3A5000&login_hint=ben%40example.com"
    );
    assert!(
        writer
            .drive
            .add_picked_budgets(format!("http://127.0.0.1:5000/?ids={}", created.id))
            .is_err(),
        "a budget nobody picked stays out of reach"
    );
    server.pick("ben@example.com", &created.id);
    assert!(
        writer
            .drive
            .add_picked_budgets("http://127.0.0.1:5000/?cancelled=1".into())
            .unwrap()
            .is_empty()
    );
    let added = writer
        .drive
        .add_picked_budgets(format!("http://127.0.0.1:5000/?ids={}", created.id))
        .unwrap();
    assert_eq!(added.len(), 1);
    assert_eq!(writer.drive.cached_budgets(), added);
    server.pick("cy@example.com", &created.id);

    let discovered = writer.drive.list_budgets().unwrap();
    assert_eq!(discovered.len(), 1);
    assert!(discovered[0].shared_with_me && discovered[0].can_edit);
    assert_eq!(
        discovered[0].owner_email.as_deref(),
        Some("ana@example.com")
    );

    let writer_path = writer
        .drive
        .open_budget(created.id.clone())
        .unwrap()
        .local_path;
    app_edit(&writer_path, |budget| {
        add_transaction(budget, "Groceries", 5000)
    });
    assert!(
        writer
            .drive
            .sync_budget(created.id.clone())
            .unwrap()
            .remote_changed
    );
    let owner_result = owner.drive.sync_budget(created.id.clone()).unwrap();
    assert!(owner_result.local_changed);
    assert_eq!(
        transaction_titles(&read_budget(&owner_result.local_path)),
        vec!["Groceries"]
    );

    let reader_budget = &reader.drive.list_budgets().unwrap()[0];
    assert!(reader_budget.shared_with_me && !reader_budget.can_edit);
    let reader_path = reader
        .drive
        .open_budget(created.id.clone())
        .unwrap()
        .local_path;
    app_edit(&reader_path, |budget| add_transaction(budget, "Sneaky", 1));
    let reader_result = reader.drive.sync_budget(created.id.clone()).unwrap();
    assert!(!reader_result.remote_changed, "readers never upload");

    // Revoking access hides the budget and removes its unchanged copy.
    let ben = shares
        .iter()
        .find(|s| s.email.as_deref() == Some("ben@example.com"))
        .unwrap();
    owner
        .drive
        .remove_share(created.id.clone(), ben.id.clone())
        .unwrap();
    assert!(writer.drive.list_budgets().unwrap().is_empty());
    assert!(!Path::new(&writer_path).exists());
    // A reader with local edits that never reached Drive keeps them.
    let cy = shares
        .iter()
        .find(|s| s.email.as_deref() == Some("cy@example.com"))
        .unwrap();
    owner
        .drive
        .remove_share(created.id.clone(), cy.id.clone())
        .unwrap();
    assert_eq!(reader.drive.list_budgets().unwrap().len(), 1);
    assert!(Path::new(&reader_path).exists());
}

#[test]
fn expired_tokens_refresh_and_revoked_sign_ins_ask_to_sign_in_again() {
    let server = FakeDrive::default();
    let device = signed_in(&server, "ana@example.com");
    device
        .drive
        .create_budget("A".into(), new_budget_json("A"))
        .unwrap();

    server.expire_access_tokens();
    assert_eq!(device.drive.list_budgets().unwrap().len(), 1);

    server.expire_access_tokens();
    server.revoke_refresh_tokens();
    let error = device.drive.list_budgets().unwrap_err();
    assert!(is_cloud_sign_in_required(error));
    assert!(!device.drive.is_signed_in());
    // Working copies stay listed offline.
    assert_eq!(device.drive.cached_budgets().len(), 1);
}

#[test]
fn sign_out_revokes_and_forgets_working_copies() {
    let server = FakeDrive::default();
    let device = signed_in(&server, "ana@example.com");
    let created = device
        .drive
        .create_budget("A".into(), new_budget_json("A"))
        .unwrap();
    device.drive.sign_out();
    assert!(!device.drive.is_signed_in());
    assert!(device.drive.cached_budgets().is_empty());
    assert!(!Path::new(&created.local_path.unwrap()).exists());
    assert!(
        server
            .state
            .lock()
            .unwrap()
            .requests
            .iter()
            .any(|r| r.starts_with(&format!("POST {REVOCATION_ENDPOINT}")))
    );
}

#[test]
fn a_deleted_app_folder_is_recreated() {
    let server = FakeDrive::default();
    let device = signed_in(&server, "ana@example.com");
    let first = device
        .drive
        .create_budget("A".into(), new_budget_json("A"))
        .unwrap();
    let folder = server.file(&first.id).parents[0].clone();
    server.state.lock().unwrap().files.remove(&folder);
    let second = device
        .drive
        .create_budget("B".into(), new_budget_json("B"))
        .unwrap();
    assert_ne!(server.file(&second.id).parents[0], folder);
}

struct StaticTokens(Arc<Mutex<Vec<bool>>>, String);

impl BWGoogleTokenSource for StaticTokens {
    fn access_token(&self, force_refresh: bool) -> Result<Option<String>, String> {
        self.0.lock().unwrap().push(force_refresh);
        Ok(Some(self.1.clone()))
    }
}

#[test]
fn platform_token_sources_replace_the_oauth_flow() {
    let server = FakeDrive::default();
    let device = device(&server);
    server
        .state
        .lock()
        .unwrap()
        .access_tokens
        .insert("play-token".into(), "dee@example.com".into());
    let calls = Arc::new(Mutex::new(Vec::new()));
    device
        .drive
        .use_token_source(Box::new(StaticTokens(calls.clone(), "play-token".into())));
    assert!(device.drive.is_configured());
    assert!(!device.drive.is_signed_in());
    assert_eq!(
        device.drive.refresh_account().unwrap().email.as_deref(),
        Some("dee@example.com")
    );
    assert!(device.drive.is_signed_in());
    device
        .drive
        .create_budget("Play".into(), new_budget_json("Play"))
        .unwrap();
    assert!(calls.lock().unwrap().iter().all(|forced| !forced));
}

#[test]
fn picker_links_need_a_configured_page_and_only_add_budgets() {
    let server = FakeDrive::default();
    let device = signed_in(&server, "ana@example.com");
    assert!(device.drive.is_picker_configured());
    assert_eq!(
        device.drive.shared_budget_picker_url(None).unwrap(),
        "https://example.com/pick"
    );
    assert!(
        device
            .drive
            .add_picked_budgets("http://127.0.0.1:1/?error=popup_closed".into())
            .unwrap_err()
            .contains("popup_closed")
    );

    // A non-budget file chosen in the picker is rejected.
    let created = device
        .drive
        .create_budget("A".into(), new_budget_json("A"))
        .unwrap();
    server
        .state
        .lock()
        .unwrap()
        .files
        .get_mut(&created.id)
        .unwrap()
        .name = "notes.txt".into();
    server
        .state
        .lock()
        .unwrap()
        .files
        .get_mut(&created.id)
        .unwrap()
        .mime_type = "text/plain".into();
    assert!(device.drive.add_budgets(vec![created.id.clone()]).is_err());

    let unconfigured = BWGoogleDrive::new(BWGoogleDriveConfig {
        client_id: "test-client".into(),
        client_secret: None,
        cache_directory: device.directory.to_string_lossy().into_owned(),
        folder_name: "Budget Warden".into(),
        picker_url: None,
    });
    assert!(!unconfigured.is_picker_configured());
    assert!(unconfigured.shared_budget_picker_url(None).is_err());
}
