//! `budget-warden cloud`: budgets stored in Google Drive.
//!
//! Cloud budgets are mirrored to working copies under the CLI config
//! directory. `cloud sync` prints a working copy's path; every other command
//! edits it with `--file` as usual, and a later `cloud sync` uploads the edits.

use std::io::Write;
use std::path::PathBuf;

use bw_core::cloud::native::{
    FileCredentialStore, NativeHttpClient, desktop_google_config, open_in_browser,
};
use bw_core::cloud::{
    BWCloudBudget, BWCloudShare, BWCloudShareRole, BWCloudSyncResult, BWGoogleDrive,
    BWGoogleLoopbackReceiver, cloud_error_message, is_cloud_sign_in_required,
};
use serde_json::{Value, json};

use crate::args::{CloudCommand, CloudRoleArg};
use crate::commands::Context;
use crate::config;
use crate::error::{ApiError, usage_error};
use crate::protocol::Meta;
use crate::storage;
use crate::{Outcome, success};

pub(crate) fn command_name(command: &CloudCommand) -> &'static str {
    match command {
        CloudCommand::Status => "status",
        CloudCommand::SignIn(_) => "sign-in",
        CloudCommand::SignOut => "sign-out",
        CloudCommand::List(_) => "list",
        CloudCommand::AddShared(_) => "add-shared",
        CloudCommand::Sync(_) => "sync",
        CloudCommand::Upload(_) => "upload",
        CloudCommand::Share(_) => "share",
        CloudCommand::Shares(_) => "shares",
        CloudCommand::Unshare(_) => "unshare",
    }
}

fn drive(context: &Context) -> BWGoogleDrive {
    let directory = config::config_dir(context.config_dir());
    let drive = BWGoogleDrive::new(desktop_google_config(&directory.join("cloud")));
    drive.connect(
        Box::new(NativeHttpClient::new()),
        Box::new(FileCredentialStore::new(
            directory.join("google-credentials.json"),
        )),
    );
    drive
}

fn sign_in_required(message: impl Into<String>) -> ApiError {
    ApiError::new("sign_in_required", message, 7)
        .details(json!({"hint": "Run `budget-warden cloud sign-in`."}))
}

/// Maps a core cloud error to a CLI error with a stable code.
fn cloud_error(message: String) -> ApiError {
    if is_cloud_sign_in_required(message.clone()) {
        return sign_in_required(cloud_error_message(message));
    }
    let retryable = message.contains("Could not reach") || message.contains("busy");
    ApiError::new("cloud_error", message, if retryable { 6 } else { 4 }).retryable(retryable)
}

fn require_configured(drive: &BWGoogleDrive) -> Result<(), ApiError> {
    if drive.is_configured() {
        return Ok(());
    }
    Err(ApiError::new(
        "cloud_not_configured",
        "Google Drive is not configured. Set BUDGET_WARDEN_GOOGLE_CLIENT_ID and BUDGET_WARDEN_GOOGLE_CLIENT_SECRET to a Google OAuth desktop client.",
        2,
    ))
}

pub(crate) fn run(mut context: Context, command: CloudCommand) -> Result<Outcome, ApiError> {
    let name = format!("cloud {}", command_name(&command));
    let drive = drive(&context);
    let data = match command {
        CloudCommand::Status => json!({
            "provider": "google_drive",
            "configured": drive.is_configured(),
            "signed_in": drive.is_signed_in(),
            "account": drive.account().map(|account| json!({"email": account.email, "name": account.display_name})),
            "working_directory": drive.working_directory(),
        }),
        CloudCommand::SignIn(args) => {
            require_configured(&drive)?;
            let receiver = BWGoogleLoopbackReceiver::new();
            let redirect = receiver.start().map_err(cloud_error)?;
            let request = drive.begin_sign_in(redirect).map_err(cloud_error)?;
            let mut stderr = std::io::stderr().lock();
            if args.no_browser || open_in_browser(&request.authorization_url).is_err() {
                let _ = writeln!(
                    stderr,
                    "Open this URL to sign in to Google Drive:\n{}",
                    request.authorization_url
                );
            } else {
                let _ = writeln!(
                    stderr,
                    "Continue signing in to Google Drive in your browser."
                );
            }
            drop(stderr);
            let callback = receiver
                .wait_for_redirect(args.timeout)
                .map_err(cloud_error)?;
            let account = drive.complete_sign_in(callback).map_err(cloud_error)?;
            json!({"signed_in": true, "account": {"email": account.email, "name": account.display_name}})
        }
        CloudCommand::SignOut => {
            let was_signed_in = drive.is_signed_in();
            drive.sign_out();
            json!({"signed_out": was_signed_in})
        }
        CloudCommand::AddShared(args) => {
            require_configured(&drive)?;
            if !drive.is_signed_in() {
                return Err(sign_in_required(
                    "Sign in to Google Drive to add shared budgets.",
                ));
            }
            let receiver = BWGoogleLoopbackReceiver::new();
            let redirect = receiver.start().map_err(cloud_error)?;
            let url = drive
                .shared_budget_picker_url(Some(format!("{redirect}/picked")))
                .map_err(|message| ApiError::new("cloud_not_configured", message, 2))?;
            let mut stderr = std::io::stderr().lock();
            if args.no_browser || open_in_browser(&url).is_err() {
                let _ = writeln!(
                    stderr,
                    "Open this URL to choose budgets shared with you:\n{url}"
                );
            } else {
                let _ = writeln!(
                    stderr,
                    "Choose the budgets shared with you in your browser."
                );
            }
            drop(stderr);
            let callback = receiver
                .wait_for_redirect(args.timeout)
                .map_err(cloud_error)?;
            let added = drive.add_picked_budgets(callback).map_err(cloud_error)?;
            json!({"added": added.iter().map(budget_value).collect::<Vec<_>>()})
        }
        CloudCommand::List(args) => {
            let budgets = if args.offline {
                drive.cached_budgets()
            } else {
                require_configured(&drive)?;
                drive.list_budgets().map_err(cloud_error)?
            };
            json!({"budgets": budgets.iter().map(budget_value).collect::<Vec<_>>()})
        }
        CloudCommand::Sync(args) => {
            require_configured(&drive)?;
            context.ensure_core(true)?;
            let id = match (args.id, args.file) {
                (Some(id), _) => id,
                (None, Some(file)) => {
                    let path = storage::absolute_path(&file)?;
                    drive
                        .budget_id_for_path(path.to_string_lossy().into_owned())
                        .ok_or_else(|| usage_error("That file is not a cloud budget working copy. Use `cloud upload` to put it in Google Drive."))?
                }
                (None, None) => return Err(usage_error("Pass --id or --file.")),
            };
            sync_value(&drive.sync_budget(id).map_err(cloud_error)?)
        }
        CloudCommand::Upload(args) => {
            require_configured(&drive)?;
            context.ensure_core(true)?;
            let path = storage::absolute_path(&args.file)?;
            let json = std::fs::read_to_string(&path)
                .map_err(|error| crate::error::io_error(error, path.display().to_string()))?;
            let name = args.name.unwrap_or_else(|| file_name(&path));
            let budget = drive.create_budget(name, json).map_err(cloud_error)?;
            json!({"budget": budget_value(&budget)})
        }
        CloudCommand::Share(args) => {
            require_configured(&drive)?;
            let role = match args.role {
                CloudRoleArg::Writer => BWCloudShareRole::Writer,
                CloudRoleArg::Reader => BWCloudShareRole::Reader,
            };
            let share = drive
                .share_budget(args.id, args.email, role, args.message)
                .map_err(cloud_error)?;
            json!({"share": share_value(&share)})
        }
        CloudCommand::Shares(args) => {
            require_configured(&drive)?;
            let shares = drive.list_shares(args.id).map_err(cloud_error)?;
            json!({"shares": shares.iter().map(share_value).collect::<Vec<_>>()})
        }
        CloudCommand::Unshare(args) => {
            require_configured(&drive)?;
            drive
                .remove_share(args.id, args.share_id.clone())
                .map_err(cloud_error)?;
            json!({"removed": args.share_id})
        }
    };
    Ok(success(&name, data, Some(Meta::command(&name))))
}

fn file_name(path: &std::path::Path) -> String {
    path.file_name()
        .map(|name| name.to_string_lossy().into_owned())
        .unwrap_or_else(|| "Budget.budget".to_string())
}

fn budget_value(budget: &BWCloudBudget) -> Value {
    json!({
        "id": budget.id,
        "name": budget.name,
        "title": budget.title,
        "owner_name": budget.owner_name,
        "owner_email": budget.owner_email,
        "shared_with_me": budget.shared_with_me,
        "is_shared": budget.is_shared,
        "can_edit": budget.can_edit,
        "can_share": budget.can_share,
        "modified_time": budget.modified_time,
        "web_link": budget.web_link,
        "local_path": budget.local_path.as_ref().map(PathBuf::from),
    })
}

fn sync_value(result: &BWCloudSyncResult) -> Value {
    json!({
        "budget": budget_value(&result.budget),
        "file": result.local_path,
        "local_changed": result.local_changed,
        "remote_changed": result.remote_changed,
    })
}

fn share_value(share: &BWCloudShare) -> Value {
    json!({
        "id": share.id,
        "role": match share.role {
            BWCloudShareRole::Owner => "owner",
            BWCloudShareRole::Writer => "writer",
            BWCloudShareRole::Commenter => "commenter",
            BWCloudShareRole::Reader => "reader",
        },
        "email": share.email,
        "name": share.display_name,
        "kind": share.kind,
    })
}
