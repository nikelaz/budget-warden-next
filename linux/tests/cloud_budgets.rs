use std::path::Path;
use std::sync::Arc;
use std::time::{Duration, Instant};

use budget_warden_linux::cloud::{CloudController, CloudEvent, budget_subtitle};
use budget_warden_linux::store::{AppState, BudgetTemplate};
use bw_core::cloud::testing::{FakeDrive, MemoryCredentials};
use bw_core::cloud::{BWCloudShareRole, BWCloudSyncResult, BWGoogleDrive, BWGoogleDriveConfig};
use bw_core::models::BWCategoryType;
use chrono::NaiveDate;
use uuid::Uuid;

struct Device {
    cloud: CloudController,
    directory: std::path::PathBuf,
}

impl Drop for Device {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.directory);
    }
}

fn device(server: &FakeDrive, email: &str) -> Device {
    let directory = std::env::temp_dir().join(format!("bw-linux-cloud-{}", Uuid::new_v4()));
    let drive = BWGoogleDrive::new(BWGoogleDriveConfig {
        client_id: "test-client".into(),
        client_secret: None,
        cache_directory: directory.to_string_lossy().into_owned(),
        folder_name: "Budget Warden".into(),
        picker_url: Some("https://example.com/pick".into()),
    });
    drive.connect(
        Box::new(server.clone()),
        Box::new(MemoryCredentials::default()),
    );
    let request = drive.begin_sign_in("http://127.0.0.1:9".into()).unwrap();
    drive
        .complete_sign_in(server.approve(&request.authorization_url, email))
        .unwrap();
    let browser = FakeBrowser {
        server: server.clone(),
        email: email.to_string(),
    };
    Device {
        cloud: CloudController::with_drive_and_browser(
            Arc::new(drive),
            Arc::new(move |url| browser.open(url)),
        ),
        directory,
    }
}

/// Plays the picker page: the user chooses the budget its link preselects,
/// or every budget shared with them, and the page returns to the app.
struct FakeBrowser {
    server: FakeDrive,
    email: String,
}

impl FakeBrowser {
    fn open(&self, url: &str) -> Result<(), String> {
        let pairs = bw_core::cloud::testing::query(url);
        let value = |name: &str| {
            pairs
                .iter()
                .find(|(key, _)| key == name)
                .map(|(_, value)| value.clone())
        };
        let return_to = value("return_to").ok_or("the picker needs a return address")?;
        let ids: Vec<String> = self
            .server
            .state
            .lock()
            .unwrap()
            .files
            .iter()
            .filter(|(_, file)| {
                file.permissions
                    .iter()
                    .any(|(_, email, _)| *email == self.email)
            })
            .map(|(id, _)| id.clone())
            .collect();
        for id in &ids {
            self.server.pick(&self.email, id);
        }
        let target = format!("{return_to}?ids={}", ids.join(","));
        std::thread::spawn(move || {
            let rest = target.trim_start_matches("http://");
            let (host, path) = rest.split_once('/').unwrap();
            let mut stream = std::net::TcpStream::connect(host).unwrap();
            use std::io::{Read, Write};
            write!(stream, "GET /{path} HTTP/1.1\r\nHost: {host}\r\n\r\n").unwrap();
            let mut answer = String::new();
            let _ = stream.read_to_string(&mut answer);
        });
        Ok(())
    }
}

/// Waits for background cloud work and returns the events it produced.
fn wait_for(
    cloud: &mut CloudController,
    mut done: impl FnMut(&[CloudEvent]) -> bool,
) -> Vec<CloudEvent> {
    let deadline = Instant::now() + Duration::from_secs(10);
    let mut events = Vec::new();
    while Instant::now() < deadline {
        events.extend(cloud.drain_events());
        if done(&events) {
            return events;
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    panic!("timed out waiting for cloud events: {events:?}");
}

fn synced(events: &[CloudEvent]) -> Vec<&BWCloudSyncResult> {
    events
        .iter()
        .filter_map(|event| match event {
            CloudEvent::Synced(Ok(result)) => Some(result),
            CloudEvent::Synced(Err(error)) => panic!("sync failed: {error}"),
            _ => None,
        })
        .collect()
}

#[test]
fn cloud_budgets_are_created_edited_shared_and_discovered() {
    let config_home =
        std::env::temp_dir().join(format!("bw-linux-cloud-config-{}", Uuid::new_v4()));
    // The only test in this binary that reads XDG_CONFIG_HOME.
    unsafe { std::env::set_var("XDG_CONFIG_HOME", &config_home) };
    let server = FakeDrive::default();
    let mut owner = device(&server, "ana@example.com");
    let mut partner = device(&server, "ben@example.com");
    let mut app = AppState::new().unwrap();

    // Create in Google Drive from a template, then open the working copy.
    let json = app
        .new_budget_json("Household", &BudgetTemplate::BasicMonthly)
        .unwrap();
    owner.cloud.create("Household.budget".into(), json);
    let events = wait_for(&mut owner.cloud, |events| !events.is_empty());
    let CloudEvent::Created(Ok(created)) = &events[0] else {
        panic!("unexpected {events:?}");
    };
    let path = created.local_path.clone().unwrap();
    assert!(owner.cloud.is_cloud_path(Path::new(&path)));
    assert_eq!(
        owner.cloud.budget_id_for_path(Path::new(&path)),
        Some(created.id.clone())
    );
    assert_eq!(owner.cloud.budgets.len(), 1);
    app.open_budget(Path::new(&path)).unwrap();
    assert!(
        owner.cloud.local_files(&app.recent_files).is_empty(),
        "cloud copies are listed separately"
    );

    // An edit marks the budget for sync; repeated requests coalesce.
    let expenses = app
        .budget
        .as_ref()
        .unwrap()
        .categories
        .iter()
        .find(|category| category.category_type == BWCategoryType::Expenses)
        .unwrap()
        .id;
    app.create_transaction(
        expenses,
        "Groceries",
        "",
        NaiveDate::from_ymd_opt(2026, 10, 20).unwrap(),
        4250,
    )
    .unwrap();
    assert!(app.take_saved_since_sync());
    assert!(!app.take_saved_since_sync());
    for _ in 0..3 {
        owner.cloud.sync(created.id.clone());
    }
    let events = wait_for(&mut owner.cloud, |events| {
        synced(events).iter().any(|result| result.remote_changed)
    });
    assert!(synced(&events).len() <= 2);

    // Share with a partner, who discovers it and edits it.
    owner.cloud.share(
        created.id.clone(),
        "ben@example.com".into(),
        BWCloudShareRole::Writer,
        None,
    );
    wait_for(&mut owner.cloud, |events| {
        events
            .iter()
            .any(|event| matches!(event, CloudEvent::Shared(_, Ok(_))))
    });
    // drive.file: the partner sees the budget only after choosing it in the
    // picker, as the invitation's link asks them to.
    partner.cloud.refresh();
    wait_for(&mut partner.cloud, |events| {
        events
            .iter()
            .any(|event| matches!(event, CloudEvent::Listed(Ok(_))))
    });
    assert!(partner.cloud.budgets.is_empty());
    assert!(partner.cloud.can_add_shared());
    partner.cloud.add_shared();
    assert!(partner.cloud.is_adding_shared());
    let events = wait_for(&mut partner.cloud, |events| {
        events
            .iter()
            .any(|event| matches!(event, CloudEvent::Added(_)))
    });
    let Some(CloudEvent::Added(Ok(added))) = events
        .iter()
        .find(|event| matches!(event, CloudEvent::Added(_)))
    else {
        panic!("unexpected {events:?}");
    };
    assert_eq!(added.len(), 1);
    assert!(!partner.cloud.is_adding_shared());
    let shared = partner.cloud.budgets[0].clone();
    assert!(shared.shared_with_me);
    assert_eq!(budget_subtitle(&shared), "Shared by ana");
    partner.cloud.open(shared.id.clone());
    let events = wait_for(&mut partner.cloud, |events| {
        events
            .iter()
            .any(|event| matches!(event, CloudEvent::Opened(_)))
    });
    let Some(CloudEvent::Opened(Ok(opened))) = events
        .iter()
        .find(|event| matches!(event, CloudEvent::Opened(_)))
    else {
        panic!("unexpected {events:?}");
    };
    let mut partner_app = AppState::new().unwrap();
    partner_app
        .open_budget(Path::new(&opened.local_path))
        .unwrap();
    assert_eq!(
        partner_app
            .budget
            .as_ref()
            .unwrap()
            .categories
            .iter()
            .map(|c| c.transactions.len())
            .sum::<usize>(),
        1
    );
    partner_app
        .create_transaction(
            expenses,
            "Fuel",
            "",
            NaiveDate::from_ymd_opt(2026, 10, 21).unwrap(),
            6000,
        )
        .unwrap();
    partner.cloud.sync(shared.id.clone());
    wait_for(&mut partner.cloud, |events| {
        synced(events).iter().any(|result| result.remote_changed)
    });

    // The owner's next sync brings the partner's edit into the open budget.
    owner.cloud.sync(created.id.clone());
    wait_for(&mut owner.cloud, |events| {
        synced(events).iter().any(|result| result.local_changed)
    });
    app.reload_budget().unwrap();
    let mut titles: Vec<_> = app
        .budget
        .as_ref()
        .unwrap()
        .categories
        .iter()
        .flat_map(|category| category.transactions.iter().map(|tx| tx.title.clone()))
        .collect();
    titles.sort();
    assert_eq!(titles, vec!["Fuel", "Groceries"]);

    // Sharing lists the owner and partner; signing out forgets cloud budgets.
    owner.cloud.load_shares(created.id.clone());
    let events = wait_for(&mut owner.cloud, |events| {
        events
            .iter()
            .any(|event| matches!(event, CloudEvent::Shares(..)))
    });
    let Some(CloudEvent::Shares(_, Ok(shares))) = events
        .iter()
        .find(|event| matches!(event, CloudEvent::Shares(..)))
    else {
        panic!("unexpected {events:?}");
    };
    assert_eq!(shares.len(), 2);
    owner.cloud.sign_out();
    wait_for(&mut owner.cloud, |events| {
        events
            .iter()
            .any(|event| matches!(event, CloudEvent::SignedOut))
    });
    assert!(!owner.cloud.is_signed_in());
    assert!(owner.cloud.budgets.is_empty());
    assert!(!Path::new(&path).exists());
    let _ = std::fs::remove_dir_all(config_home);
}
