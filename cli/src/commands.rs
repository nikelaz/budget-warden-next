use std::fs;
use std::path::{Path, PathBuf};

use chrono::{Datelike, Local};
use serde_json::{Value, json};
use uuid::Uuid;

use crate::args::*;
use crate::config;
use crate::error::{ApiError, core_error, io_error, missing_entity, usage_error};
use crate::protocol::{Meta, PROTOCOL_VERSION};
use crate::storage::{self, LoadedBudget};
use crate::util::*;
use crate::{Outcome, success};
use bw_core::models::{BWBudget, BWCategory, BWDate, BWMoneyAmount, BWTransaction};

pub(crate) struct Context {
    config_dir: Option<PathBuf>,
    device_override: Option<Uuid>,
    core_initialized: bool,
}

impl Context {
    pub(crate) fn ensure_core(&mut self, persist_device: bool) -> Result<(), ApiError> {
        if self.core_initialized {
            return Ok(());
        }
        let id = config::device_id(
            self.config_dir.as_deref(),
            self.device_override,
            persist_device,
        )?;
        bw_core::app_state::initialize_core(id)
            .map_err(|message| ApiError::new("internal_error", message, 1))?;
        self.core_initialized = true;
        Ok(())
    }

    pub(crate) fn config_dir(&self) -> Option<&Path> {
        self.config_dir.as_deref()
    }
}

pub fn command_name(command: &Command) -> String {
    match command {
        Command::Capabilities => "capabilities".into(),
        Command::Budget { command } => format!("budget {}", budget_name(command)),
        Command::Template { command } => format!(
            "template {}",
            match command {
                TemplateCommand::List => "list",
                TemplateCommand::Show { .. } => "show",
            }
        ),
        Command::Category { command } => format!("category {}", category_name(command)),
        Command::Transaction { command } => format!("transaction {}", transaction_name(command)),
        Command::Report { command } => format!(
            "report {}",
            match command {
                ReportCommand::Summary(_) => "summary",
                ReportCommand::Allocation(_) => "allocation",
                ReportCommand::Categories(_) => "categories",
                ReportCommand::Comparison(_) => "comparison",
            }
        ),
        Command::Config { command } => format!(
            "config {}",
            match command {
                ConfigCommand::Show => "show",
                ConfigCommand::Set { .. } => "set",
                ConfigCommand::Paths => "paths",
            }
        ),
        Command::Recent { command } => format!(
            "recent {}",
            match command {
                RecentCommand::List => "list",
                RecentCommand::Add { .. } => "add",
                RecentCommand::Remove { .. } => "remove",
            }
        ),
        Command::Apply(_) => "apply".into(),
        Command::Cloud { command } => format!("cloud {}", crate::cloud::command_name(command)),
    }
}

fn budget_name(command: &BudgetCommand) -> &'static str {
    match command {
        BudgetCommand::Create(_) => "create",
        BudgetCommand::Show(_) => "show",
        BudgetCommand::Rename(_) => "rename",
        BudgetCommand::Copy(_) => "copy",
        BudgetCommand::Move(_) => "move",
        BudgetCommand::Delete(_) => "delete",
        BudgetCommand::Validate(_) => "validate",
        BudgetCommand::Migrate(_) => "migrate",
        BudgetCommand::Merge(_) => "merge",
        BudgetCommand::List(_) => "list",
    }
}
fn category_name(command: &CategoryCommand) -> &'static str {
    match command {
        CategoryCommand::List(_) => "list",
        CategoryCommand::Show(_) => "show",
        CategoryCommand::Create(_) => "create",
        CategoryCommand::Update(_) => "update",
        CategoryCommand::Delete(_) => "delete",
        CategoryCommand::Move(_) => "move",
    }
}
fn transaction_name(command: &TransactionCommand) -> &'static str {
    match command {
        TransactionCommand::List(_) => "list",
        TransactionCommand::Show(_) => "show",
        TransactionCommand::Create(_) => "create",
        TransactionCommand::Update(_) => "update",
        TransactionCommand::Delete(_) => "delete",
        TransactionCommand::Move(_) => "move",
    }
}

pub fn dispatch(cli: Cli) -> Result<Outcome, ApiError> {
    let context = Context {
        config_dir: cli.config_dir,
        device_override: cli.device_id,
        core_initialized: false,
    };
    match cli.command {
        Command::Capabilities => capabilities(),
        Command::Budget { command } => run_budget(context, command),
        Command::Template { command } => run_template(context, command),
        Command::Category { command } => run_category(context, command),
        Command::Transaction { command } => run_transaction(context, command),
        Command::Report { command } => run_report(command),
        Command::Config { command } => run_config(context, command),
        Command::Recent { command } => run_recent(context, command),
        Command::Apply(args) => crate::batch::run_apply(context, args),
        Command::Cloud { command } => crate::cloud::run(context, command),
    }
}

fn capabilities() -> Result<Outcome, ApiError> {
    let commands = vec![
        "budget create",
        "budget show",
        "budget rename",
        "budget copy",
        "budget move",
        "budget delete",
        "budget validate",
        "budget migrate",
        "budget merge",
        "budget list",
        "template list",
        "template show",
        "category list",
        "category show",
        "category create",
        "category update",
        "category delete",
        "category move",
        "transaction list",
        "transaction show",
        "transaction create",
        "transaction update",
        "transaction delete",
        "transaction move",
        "report summary",
        "report allocation",
        "report categories",
        "report comparison",
        "config show",
        "config set",
        "config paths",
        "recent list",
        "recent add",
        "recent remove",
        "apply",
        "cloud status",
        "cloud sign-in",
        "cloud sign-out",
        "cloud list",
        "cloud add-shared",
        "cloud sync",
        "cloud upload",
        "cloud share",
        "cloud shares",
        "cloud unshare",
    ];
    let templates = bw_core::templates::template_catalog()
        .iter()
        .map(template_summary_value)
        .collect::<Vec<_>>();
    let schema: Value = serde_json::from_str(include_str!("../protocol/v1.schema.json"))
        .map_err(|error| ApiError::new("internal_error", error.to_string(), 1))?;
    let envelope_schema: Value =
        serde_json::from_str(include_str!("../protocol/v1-envelope.schema.json"))
            .map_err(|error| ApiError::new("internal_error", error.to_string(), 1))?;
    let output_schema: Value =
        serde_json::from_str(include_str!("../protocol/v1-output.schema.json"))
            .map_err(|error| ApiError::new("internal_error", error.to_string(), 1))?;
    let data = json!({
        "cli_version": env!("CARGO_PKG_VERSION"),
        "core_version": env!("BW_CORE_VERSION"),
        "core_package": "bw_core",
        "core_dependency": "../core",
        "target": {"os":std::env::consts::OS,"architecture":std::env::consts::ARCH},
        "protocol_version": PROTOCOL_VERSION,
        "budget_schema_version": 2,
        "commands": commands,
        "templates": templates,
        "category_types": ["income", "expenses", "savings", "debt"],
        "money": {"decimal_scale": 2, "decimal_input": "string", "minor_units_input": "integer string"},
        "date": "YYYY-MM-DD",
        "features": {"json_input": true, "dry_run": true, "revision_preconditions": true, "locking": "local CLI processes", "atomic_batches": true},
        "schemas": {"apply_request": schema, "response_envelope": envelope_schema, "response_data": output_schema},
    });
    Ok(success(
        "capabilities",
        data,
        Some(Meta::command("capabilities")),
    ))
}

fn run_budget(mut context: Context, command: BudgetCommand) -> Result<Outcome, ApiError> {
    match command {
        BudgetCommand::Create(args) => budget_create(&mut context, args),
        BudgetCommand::Show(args) => {
            let loaded = storage::load(&args.file)?;
            let data = budget_value(&loaded.budget);
            Ok(success(
                "budget show",
                data,
                Some(meta_for_loaded("budget show", &loaded, false)),
            ))
        }
        BudgetCommand::Rename(args) => {
            let (budget, original, wrote, ()) = mutate(
                &mut context,
                &args.file.file,
                args.if_revision,
                args.dry_run,
                |budget| {
                    let updated = bw_core::domain::update_budget_title(budget, args.title.clone())
                        .map_err(|message| core_error("mutation_failed", message))?;
                    Ok((updated, ()))
                },
            )?;
            Ok(success(
                "budget rename",
                json!({"budget_id": budget.id, "title": budget.title, "dry_run":args.dry_run}),
                Some(meta_for_mutation(
                    "budget rename",
                    &budget,
                    original.requires_migration_writeback,
                    wrote,
                )),
            ))
        }
        BudgetCommand::Copy(args) => budget_copy(args),
        BudgetCommand::Move(args) => budget_move(args),
        BudgetCommand::Delete(args) => {
            if args.dry_run {
                let loaded = storage::load(&args.file.file)?;
                if loaded.budget.id != args.confirm_budget_id {
                    return Err(ApiError::new("budget_id_mismatch", "Confirmation ID does not match this budget", 2).details(json!({"expected_budget_id":args.confirm_budget_id,"actual_budget_id":loaded.budget.id})).outcome("not_written"));
                }
                check_revision(
                    args.if_revision,
                    loaded.budget.revision_id,
                    "Budget revision changed before deletion",
                )?;
                return Ok(success(
                    "budget delete",
                    json!({"deleted":false,"dry_run":true,"budget_id":loaded.budget.id}),
                    Some(meta_for_loaded("budget delete", &loaded, false)),
                ));
            }
            let budget =
                storage::remove_budget(&args.file.file, args.confirm_budget_id, args.if_revision)?;
            Ok(success(
                "budget delete",
                json!({"deleted": true, "budget_id": budget.id}),
                Some(Meta::command("budget delete").budget(
                    budget.id,
                    budget.revision,
                    budget.revision_id,
                    true,
                )),
            ))
        }
        BudgetCommand::Validate(args) => {
            let loaded = storage::load(&args.file)?;
            bw_core::validation::validate_budget(&loaded.budget)
                .map_err(|message| core_error("validation_failed", message))?;
            Ok(success(
                "budget validate",
                json!({"valid": true, "budget_id": loaded.budget.id, "title": loaded.budget.title}),
                Some(meta_for_loaded("budget validate", &loaded, false)),
            ))
        }
        BudgetCommand::Migrate(args) => budget_migrate(args),
        BudgetCommand::Merge(args) => budget_merge(args),
        BudgetCommand::List(args) => budget_list(args),
    }
}

fn budget_create(context: &mut Context, args: BudgetCreateArgs) -> Result<Outcome, ApiError> {
    if args.template.is_none() && args.from.is_none() {
        return Err(usage_error(
            "Choose --template TEMPLATE_ID or --from PATH; list available IDs with `template list`",
        ));
    }
    if args.template.is_some() && args.from.is_some() {
        return Err(usage_error("Choose either --template or --from"));
    }
    if args.title.trim().is_empty() {
        return Err(usage_error("Budget title cannot be empty"));
    }
    if let Some(template_id) = &args.template
        && !bw_core::templates::template_catalog()
            .iter()
            .any(|template| template.id == *template_id)
    {
        return Err(usage_error(format!(
            "Unknown budget template ID '{template_id}'. List available IDs with `template list`."
        )));
    }
    context.ensure_core(!args.dry_run)?;
    let budget = if let Some(template_id) = args.template {
        bw_core::templates::budget_from_template_id(template_id, args.title.clone())
            .map_err(|message| core_error("mutation_failed", message))?
    } else {
        let source = storage::load(args.from.as_ref().expect("checked above"))?;
        bw_core::templates::budget_from_previous_budget(source.budget, args.title.clone())
            .map_err(|message| core_error("mutation_failed", message))?
    };
    if args.dry_run {
        let destination = available_destination(&args.file, args.overwrite_budget_id)?;
        return Ok(success(
            "budget create",
            json!({"budget":budget_value(&budget),"creation_mode":if args.from.is_some() {"new_from_existing"} else {"template"},"destination":destination,"dry_run":true}),
            Some(
                Meta::command("budget create")
                    .budget(budget.id, budget.revision, budget.revision_id, false)
                    .migration(false),
            ),
        ));
    }
    storage::write_new(&args.file, &budget, args.overwrite_budget_id)?;
    let loaded = storage::load(&args.file).map_err(|error| error.outcome("written"))?;
    Ok(success(
        "budget create",
        json!({"budget": budget_value(&loaded.budget), "creation_mode": if args.from.is_some() { "new_from_existing" } else { "template" }}),
        Some(meta_for_loaded("budget create", &loaded, true)),
    ))
}

fn budget_copy(args: BudgetCopyArgs) -> Result<Outcome, ApiError> {
    let source = storage::load(&args.file.file)?;
    let destination = storage::absolute_path(&args.to)?;
    if source.path == destination {
        return Err(usage_error(
            "Copy source and destination must be different paths",
        ));
    }
    if args.dry_run {
        let destination = available_destination(&args.to, args.overwrite_budget_id)?;
        return Ok(success(
            "budget copy",
            json!({"copied":false,"dry_run":true,"budget_id":source.budget.id,"from":source.path,"to":destination}),
            Some(meta_for_loaded("budget copy", &source, false)),
        ));
    }
    let source_bytes = fs::read(&source.path)
        .map_err(|error| io_error(error, source.path.display().to_string()))?;
    storage::write_new_bytes(
        &args.to,
        &source_bytes,
        source.budget.id,
        args.overwrite_budget_id,
    )?;
    let data = json!({"copied": true, "budget_id": source.budget.id, "from": source.path, "to": storage::absolute_path(&args.to)?});
    Ok(success(
        "budget copy",
        data,
        Some(meta_for_loaded("budget copy", &source, true)),
    ))
}

fn budget_move(args: BudgetMoveArgs) -> Result<Outcome, ApiError> {
    let source = storage::load(&args.file.file)?;
    let source_path = source.path.clone();
    let destination = storage::absolute_path(&args.to)?;
    if source_path == destination {
        return Err(usage_error(
            "Move source and destination must be different paths",
        ));
    }
    if args.dry_run {
        check_revision(
            args.if_revision,
            source.budget.revision_id,
            "Source budget revision changed before move",
        )?;
        let destination = available_destination(&destination, args.overwrite_budget_id)?;
        return Ok(success(
            "budget move",
            json!({"moved":false,"dry_run":true,"budget_id":source.budget.id,"from":source_path,"to":destination}),
            Some(meta_for_loaded("budget move", &source, false)),
        ));
    }
    let mut locks = vec![source_path.clone(), destination.clone()];
    locks.sort();
    let mut guards = Vec::new();
    for path in &locks {
        guards.push(storage::lock(path)?);
    }
    storage::reject_symlink(&source_path)?;
    storage::reject_symlink(&destination)?;
    let latest = storage::load(&source_path)?;
    if latest.budget.revision_id != source.budget.revision_id
        || args
            .if_revision
            .is_some_and(|expected| expected != latest.budget.revision_id)
    {
        return Err(ApiError::new("revision_conflict", "Source budget changed before move", 5).retryable(true)
            .details(json!({"expected_revision_id":args.if_revision,"actual_revision_id":latest.budget.revision_id})).outcome("not_written"));
    }
    let source_bytes = fs::read(&source_path)
        .map_err(|error| io_error(error, source_path.display().to_string()))?;
    storage::create_bytes_locked(
        &destination,
        &source_bytes,
        latest.budget.id,
        args.overwrite_budget_id,
    )?;
    if let Err(error) = fs::remove_file(&source_path) {
        return Err(io_error(error, source_path.display().to_string()).details(json!({"source": source_path, "destination": destination, "partial_outcome": "destination_written_source_retained"})).outcome("written"));
    }
    storage::sync_directory(source_path.parent().unwrap_or_else(|| Path::new(".")))
        .map_err(|error| io_error(error, source_path.display().to_string()).outcome("written"))?;
    let data = json!({"moved": true, "budget_id": latest.budget.id, "from": source_path, "to": destination, "partial_outcome": null});
    Ok(success(
        "budget move",
        data,
        Some(meta_for_loaded("budget move", &latest, true)),
    ))
}

fn budget_migrate(args: BudgetMigrateArgs) -> Result<Outcome, ApiError> {
    if args.to.is_none() && !args.in_place {
        return Err(usage_error("Choose --to PATH or --in-place"));
    }
    let loaded = storage::load(&args.file)?;
    if args.dry_run {
        check_revision(
            args.if_revision,
            loaded.budget.revision_id,
            "Budget revision changed before migration",
        )?;
        if let Some(destination) = args.to.as_ref() {
            if loaded.path == storage::absolute_path(destination)? {
                return Err(usage_error("Use --in-place to migrate the source file"));
            }
            let destination = available_destination(destination, args.overwrite_budget_id)?;
            bw_core::codec::encode_budget(&loaded.budget)
                .map_err(|message| core_error("encode_failed", message).outcome("not_written"))?;
            return Ok(success(
                "budget migrate",
                json!({"migrated":loaded.requires_migration_writeback,"dry_run":true,"budget_id":loaded.budget.id,"source":loaded.path,"destination":destination}),
                Some(meta_for_loaded("budget migrate", &loaded, false)),
            ));
        }
        return Ok(success(
            "budget migrate",
            json!({"migrated":loaded.requires_migration_writeback,"dry_run":true,"budget_id":loaded.budget.id}),
            Some(meta_for_loaded("budget migrate", &loaded, false)),
        ));
    }
    if let Some(destination) = args.to {
        if loaded.path == storage::absolute_path(&destination)? {
            return Err(usage_error("Use --in-place to migrate the source file"));
        }
        if let Some(expected) = args.if_revision {
            if expected != loaded.budget.revision_id {
                return Err(ApiError::new("revision_conflict", "Budget revision changed before migration", 5).retryable(true)
                    .details(json!({"expected_revision_id": expected, "actual_revision_id": loaded.budget.revision_id})).outcome("not_written"));
            }
        }
        let mut migrated_budget = loaded.budget.clone();
        if loaded.requires_migration_writeback {
            migrated_budget.revision_id = Uuid::new_v4();
        }
        let encoded = bw_core::codec::encode_budget(&migrated_budget)
            .map_err(|message| core_error("encode_failed", message).outcome("not_written"))?;
        storage::write_new_bytes(
            &destination,
            encoded.as_bytes(),
            loaded.budget.id,
            args.overwrite_budget_id,
        )?;
        let output = storage::load(&destination).map_err(|error| error.outcome("written"))?;
        Ok(success(
            "budget migrate",
            json!({"migrated": true, "source": loaded.path, "destination": output.path, "budget_id": output.budget.id, "migration_required_before": loaded.requires_migration_writeback}),
            Some(meta_for_loaded("budget migrate", &output, true)),
        ))
    } else {
        let _lock = storage::lock(&loaded.path)?;
        let latest = storage::load(&loaded.path)?;
        if let Some(expected) = args.if_revision {
            if expected != latest.budget.revision_id {
                return Err(ApiError::new("revision_conflict", "Budget revision changed before migration", 5).retryable(true)
                    .details(json!({"expected_revision_id": expected, "actual_revision_id": latest.budget.revision_id})).outcome("not_written"));
            }
        }
        if !latest.requires_migration_writeback {
            return Ok(success(
                "budget migrate",
                json!({"migrated": false, "budget_id": latest.budget.id, "reason": "already_current"}),
                Some(meta_for_loaded("budget migrate", &latest, false)),
            ));
        }
        let mut migrated_budget = latest.budget.clone();
        migrated_budget.revision_id = Uuid::new_v4();
        let encoded = bw_core::codec::encode_budget(&migrated_budget)
            .map_err(|message| core_error("encode_failed", message).outcome("not_written"))?;
        storage::replace_bytes(&latest.path, encoded.as_bytes(), latest.budget.id)?;
        let after = storage::load(&latest.path).map_err(|error| error.outcome("written"))?;
        Ok(success(
            "budget migrate",
            json!({"migrated": true, "budget_id": after.budget.id}),
            Some(meta_for_loaded("budget migrate", &after, true)),
        ))
    }
}

fn budget_merge(args: BudgetMergeArgs) -> Result<Outcome, ApiError> {
    let base = storage::load(&args.file.file)?;
    let other = storage::load(&args.other)?;
    if base.budget.id != other.budget.id {
        return Err(
            core_error("merge_failed", "Cannot merge different budgets").outcome("not_written")
        );
    }
    let merged = bw_core::domain::merge_budget_for_save(base.budget.clone(), other.budget)
        .map_err(|message| core_error("merge_failed", message).outcome("not_written"))?
        .update_actuals()
        .map_err(|message| core_error("validation_failed", message).outcome("not_written"))?;
    if let Some(destination) = args.to {
        if args.dry_run {
            if let Some(expected) = args.if_revision {
                if expected != base.budget.revision_id {
                    return Err(ApiError::new(
                        "revision_conflict",
                        "Budget revision changed before merge preview",
                        5,
                    )
                    .retryable(true)
                    .outcome("not_written"));
                }
            }
            let destination = available_destination(&destination, None)?;
            return Ok(success(
                "budget merge",
                json!({"merged":true,"dry_run":true,"budget":budget_value(&merged),"source":base.path,"other":other.path,"destination":destination}),
                Some(Meta::command("budget merge").budget(
                    merged.id,
                    merged.revision,
                    merged.revision_id,
                    false,
                )),
            ));
        }
        if let Some(expected) = args.if_revision {
            if expected != base.budget.revision_id {
                return Err(ApiError::new(
                    "revision_conflict",
                    "Budget revision changed before merge",
                    5,
                )
                .retryable(true)
                .outcome("not_written"));
            }
        }
        storage::write_new(&destination, &merged, None)?;
        let output = storage::load(&destination).map_err(|error| error.outcome("written"))?;
        Ok(success(
            "budget merge",
            json!({"merged": true, "budget": budget_value(&output.budget), "source": base.path, "other": other.path, "destination": output.path}),
            Some(meta_for_loaded("budget merge", &output, true)),
        ))
    } else {
        if args.dry_run {
            if let Some(expected) = args.if_revision {
                if expected != base.budget.revision_id {
                    return Err(ApiError::new(
                        "revision_conflict",
                        "Budget revision changed before merge preview",
                        5,
                    )
                    .retryable(true)
                    .outcome("not_written"));
                }
            }
            return Ok(success(
                "budget merge",
                json!({"merged":true,"dry_run":true,"budget":budget_value(&merged),"other":other.path}),
                Some(Meta::command("budget merge").budget(
                    merged.id,
                    merged.revision,
                    merged.revision_id,
                    false,
                )),
            ));
        }
        let _lock = storage::lock(&base.path)?;
        let latest = storage::load(&base.path)?;
        if let Some(expected) = args.if_revision {
            if latest.budget.revision_id != expected {
                return Err(ApiError::new("revision_conflict", "Budget revision changed before merge", 5).retryable(true).details(json!({"expected_revision_id":expected,"actual_revision_id":latest.budget.revision_id})).outcome("not_written"));
            }
        }
        let final_budget = if latest.budget.revision_id == base.budget.revision_id {
            merged
        } else {
            bw_core::domain::merge_budget_for_save(merged, latest.budget)
                .map_err(|message| core_error("merge_failed", message).outcome("not_written"))?
        };
        let final_budget = final_budget
            .update_actuals()
            .map_err(|message| core_error("validation_failed", message).outcome("not_written"))?;
        let encoded = bw_core::codec::encode_budget(&final_budget)
            .map_err(|message| core_error("encode_failed", message).outcome("not_written"))?;
        storage::replace_bytes(&base.path, encoded.as_bytes(), final_budget.id)?;
        Ok(success(
            "budget merge",
            json!({"merged": true, "budget": budget_value(&final_budget), "other": other.path}),
            Some(meta_for_mutation(
                "budget merge",
                &final_budget,
                base.requires_migration_writeback,
                true,
            )),
        ))
    }
}

fn budget_list(args: BudgetListArgs) -> Result<Outcome, ApiError> {
    let paths = storage::list_budget_files(&args.directory)?;
    let mut entries = Vec::new();
    for path in paths {
        match storage::load(&path) {
            Ok(loaded) => entries.push(json!({"path": loaded.path, "budget_id": loaded.budget.id, "title": loaded.budget.title, "revision": loaded.budget.revision, "revision_id": loaded.budget.revision_id, "valid": true, "migration_status": if loaded.requires_migration_writeback { "required" } else { "current" }})),
            Err(error) => entries.push(json!({"path": path, "valid": false, "error": {"code": error.code, "message": error.message}})),
        }
    }
    Ok(success(
        "budget list",
        json!({"directory": fs::canonicalize(&args.directory).map_err(|error| io_error(error, args.directory.display().to_string()))?, "budgets": entries}),
        Some(Meta::command("budget list")),
    ))
}

fn template_summary_value(template: &bw_core::templates::BWTemplateCatalogEntry) -> Value {
    json!({
        "id": template.id,
        "title": template.title,
        "family": template.family,
        "description": template.description,
        "semantics": template.description,
        "default_reporting_mode": template.default_reporting_mode,
        "setup_kind": template.setup_kind,
    })
}

fn template_detail_value(template: &bw_core::templates::BWTemplateCatalogEntry) -> Value {
    let budget = bw_core::templates::budget_from_template(
        template.template_type,
        "Template preview".to_string(),
    );
    let categories = budget
        .categories
        .iter()
        .map(category_value)
        .collect::<Vec<_>>();
    let mut value = template_summary_value(template);
    value["categories"] = json!(categories);
    value
}

fn run_template(mut context: Context, command: TemplateCommand) -> Result<Outcome, ApiError> {
    match command {
        TemplateCommand::List => Ok(success(
            "template list",
            json!(
                bw_core::templates::template_catalog()
                    .iter()
                    .map(template_summary_value)
                    .collect::<Vec<_>>()
            ),
            Some(Meta::command("template list")),
        )),
        TemplateCommand::Show { template: id } => {
            let template = bw_core::templates::template_catalog()
                .into_iter()
                .find(|template| template.id == id)
                .ok_or_else(|| {
                    usage_error(format!(
                        "Unknown budget template ID '{id}'. List available IDs with `template list`."
                    ))
                })?;
            context.ensure_core(false)?;
            Ok(success(
                "template show",
                template_detail_value(&template),
                Some(Meta::command("template show")),
            ))
        }
    }
}

fn run_config(context: Context, command: ConfigCommand) -> Result<Outcome, ApiError> {
    match command {
        ConfigCommand::Show => {
            let value = config::load(context.config_dir.as_deref())?;
            Ok(success(
                "config show",
                json!({"device_id": value.device_id, "currency": value.currency, "recent_file_count": value.recent_files.len()}),
                Some(Meta::command("config show")),
            ))
        }
        ConfigCommand::Set { currency } => {
            let currency = currency.to_ascii_uppercase();
            if currency.len() != 3 || !currency.bytes().all(|byte| byte.is_ascii_uppercase()) {
                return Err(usage_error("Currency must be a three-letter ASCII code"));
            }
            config::update(context.config_dir.as_deref(), |value| {
                value.currency = Some(currency.clone());
                Ok(())
            })?;
            Ok(success(
                "config set",
                json!({"currency": currency, "saved": true}),
                Some(Meta::command("config set")),
            ))
        }
        ConfigCommand::Paths => {
            let directory = config::config_dir(context.config_dir.as_deref());
            Ok(success(
                "config paths",
                json!({"config_directory": directory, "config_file": directory.join("config.json"), "device_id_source": "config.json or --device-id"}),
                Some(Meta::command("config paths")),
            ))
        }
    }
}

fn run_recent(context: Context, command: RecentCommand) -> Result<Outcome, ApiError> {
    match command {
        RecentCommand::List => {
            let mut value = config::load(context.config_dir.as_deref())?;
            value.recent_files.retain(|path| path.exists());
            Ok(success(
                "recent list",
                json!({"files": value.recent_files}),
                Some(Meta::command("recent list")),
            ))
        }
        RecentCommand::Add { file } => {
            let path = storage::absolute_path(&file)?;
            let count = config::update(context.config_dir.as_deref(), |value| {
                value.recent_files.retain(|existing| existing != &path);
                value.recent_files.insert(0, path.clone());
                value.recent_files.truncate(100);
                Ok(value.recent_files.len())
            })?;
            Ok(success(
                "recent add",
                json!({"added": path, "count": count}),
                Some(Meta::command("recent add")),
            ))
        }
        RecentCommand::Remove { file } => {
            let path = storage::absolute_path(&file)?;
            let removed = config::update(context.config_dir.as_deref(), |value| {
                let previous = value.recent_files.len();
                value.recent_files.retain(|existing| existing != &path);
                Ok(previous != value.recent_files.len())
            })?;
            Ok(success(
                "recent remove",
                json!({"removed": removed, "file": path}),
                Some(Meta::command("recent remove")),
            ))
        }
    }
}

fn budget_value(budget: &BWBudget) -> Value {
    let mut categories = budget.ordered_categories(None);
    categories
        .sort_by_key(|category| (category.category_type as i32, category.ordinal, category.id));
    json!({"id": budget.id, "title": budget.title, "revision": budget.revision, "revision_id": budget.revision_id, "schema_version": budget.schema_version, "categories": categories.iter().map(category_value).collect::<Vec<_>>()})
}

fn meta_for_loaded(command: &str, loaded: &LoadedBudget, wrote: bool) -> Meta {
    Meta::command(command)
        .budget(
            loaded.budget.id,
            loaded.budget.revision,
            loaded.budget.revision_id,
            wrote,
        )
        .migration(loaded.requires_migration_writeback)
}

fn check_revision(expected: Option<Uuid>, actual: Uuid, message: &str) -> Result<(), ApiError> {
    if let Some(expected) = expected {
        if expected != actual {
            return Err(ApiError::new("revision_conflict", message, 5)
                .retryable(true)
                .details(json!({"expected_revision_id":expected,"actual_revision_id":actual}))
                .outcome("not_written"));
        }
    }
    Ok(())
}

fn not_written(error: ApiError) -> ApiError {
    if error.commit_outcome.is_none() {
        error.outcome("not_written")
    } else {
        error
    }
}

fn available_destination(
    path: &Path,
    overwrite_budget_id: Option<Uuid>,
) -> Result<PathBuf, ApiError> {
    let path = storage::absolute_path(path)?;
    storage::reject_symlink(&path)?;
    if path.exists() {
        let existing = storage::load(&path)?;
        if overwrite_budget_id != Some(existing.budget.id) {
            return Err(ApiError::new(
                "destination_exists",
                "Destination already exists; provide its budget ID to replace it",
                6,
            )
            .details(json!({"path":path,"budget_id":existing.budget.id}))
            .outcome("not_written"));
        }
    }
    Ok(path)
}

pub(crate) fn meta_for_mutation(
    command: &str,
    budget: &BWBudget,
    migration_required: bool,
    wrote: bool,
) -> Meta {
    Meta::command(command)
        .budget(budget.id, budget.revision, budget.revision_id, wrote)
        .migration(migration_required && !wrote)
}

pub(crate) fn mutate<T, F>(
    context: &mut Context,
    file: &Path,
    expected_revision: Option<Uuid>,
    dry_run: bool,
    operation: F,
) -> Result<(BWBudget, LoadedBudget, bool, T), ApiError>
where
    F: FnOnce(BWBudget) -> Result<(BWBudget, T), ApiError>,
{
    context.ensure_core(!dry_run)?;
    let path = storage::absolute_path(file).map_err(not_written)?;
    storage::reject_symlink(&path).map_err(not_written)?;
    let _lock = storage::lock(&path).map_err(not_written)?;
    let loaded = storage::load(&path).map_err(not_written)?;
    if let Some(expected) = expected_revision {
        if loaded.budget.revision_id != expected {
            return Err(ApiError::new("revision_conflict", "Budget revision does not match --if-revision", 5).retryable(true)
                .details(json!({"expected_revision_id": expected, "actual_revision_id": loaded.budget.revision_id})).outcome("not_written"));
        }
    }
    let (mutated, value) = operation(loaded.budget.clone()).map_err(|error| {
        if error.commit_outcome.is_none() {
            error.outcome("not_written")
        } else {
            error
        }
    })?;
    let mutated = mutated
        .update_actuals()
        .map_err(|message| core_error("validation_failed", message).outcome("not_written"))?;
    let result = if dry_run {
        storage::preview_mutation(&loaded.budget, mutated).map_err(not_written)?
    } else {
        storage::commit_mutation(&path, expected_revision, loaded.budget.revision_id, mutated)
            .map_err(not_written)?
    };
    Ok((result, loaded, !dry_run, value))
}

fn run_category(mut context: Context, command: CategoryCommand) -> Result<Outcome, ApiError> {
    match command {
        CategoryCommand::List(args) => {
            validate_page(args.limit)?;
            let loaded = storage::load(&args.file.file)?;
            let search = args.search.as_deref().map(str::to_lowercase);
            let mut categories: Vec<_> = loaded
                .budget
                .ordered_categories(args.r#type.map(category_type))
                .into_iter()
                .filter(|category| {
                    search
                        .as_ref()
                        .is_none_or(|query| category.title.to_lowercase().contains(query))
                })
                .collect();
            categories.sort_by(|left, right| {
                let primary = match args.sort {
                    SortOrder::Ordinal => (left.category_type as i32, left.ordinal)
                        .cmp(&(right.category_type as i32, right.ordinal)),
                    SortOrder::Title => left.title.to_lowercase().cmp(&right.title.to_lowercase()),
                    SortOrder::Planned => {
                        left.amount_planned.value.cmp(&right.amount_planned.value)
                    }
                    SortOrder::Actual => left.amount_actual.value.cmp(&right.amount_actual.value),
                };
                primary.then_with(|| left.id.cmp(&right.id))
            });
            let total = categories.len();
            let rows: Vec<_> = categories
                .into_iter()
                .skip(args.offset)
                .take(args.limit)
                .map(|category| category_value(&category))
                .collect();
            Ok(success(
                "category list",
                json!({"items": rows, "total": total, "offset": args.offset, "limit": args.limit}),
                Some(meta_for_loaded("category list", &loaded, false)),
            ))
        }
        CategoryCommand::Show(args) => {
            let loaded = storage::load(&args.file.file)?;
            let category = loaded
                .budget
                .categories
                .iter()
                .find(|category| category.id == args.id)
                .ok_or_else(|| missing_entity("category", args.id.to_string()))?;
            Ok(success(
                "category show",
                category_value(category),
                Some(meta_for_loaded("category show", &loaded, false)),
            ))
        }
        CategoryCommand::Create(args) => {
            let planned = money_pair(
                args.planned.as_deref(),
                args.planned_minor_units.as_deref(),
                None,
            )?
            .ok_or_else(|| usage_error("Provide --planned or --planned-minor-units"))?;
            let accumulated = money_pair(
                args.accumulated.as_deref(),
                args.accumulated_minor_units.as_deref(),
                Some("0"),
            )?
            .expect("default amount provided");
            let category_type = category_type(args.r#type);
            let ordinal = args.ordinal;
            let (budget, original, wrote, id) = mutate(
                &mut context,
                &args.file.file,
                args.if_revision,
                args.dry_run,
                move |budget| {
                    let count = budget
                        .categories
                        .iter()
                        .filter(|category| category.category_type == category_type)
                        .count();
                    let ordinal = ordinal.unwrap_or(count);
                    if ordinal > count {
                        return Err(usage_error(
                            "Category ordinal must be between zero and the category count",
                        ));
                    }
                    let requested_ordinal = i32::try_from(ordinal)
                        .map_err(|_| usage_error("Category ordinal is too large"))?;
                    let append_ordinal = i32::try_from(count)
                        .map_err(|_| usage_error("Category count is too large"))?;
                    let category = BWCategory {
                        id: Uuid::new_v4(),
                        ordinal: append_ordinal,
                        title: args.title.clone(),
                        amount_planned: planned,
                        amount_actual: BWMoneyAmount { value: 0 },
                        amount_accumulated: accumulated,
                        category_type,
                        transactions: Vec::new(),
                    };
                    let id = category.id;
                    let mut updated = bw_core::domain::create_category(budget, category)
                        .map_err(|message| core_error("mutation_failed", message))?;
                    if requested_ordinal != append_ordinal {
                        let mut created = updated
                            .categories
                            .iter()
                            .find(|category| category.id == id)
                            .cloned()
                            .ok_or_else(|| missing_entity("category", id.to_string()))?;
                        created.ordinal = requested_ordinal;
                        updated = bw_core::domain::update_category(updated, created)
                            .map_err(|message| core_error("mutation_failed", message))?;
                    }
                    Ok((updated, id))
                },
            )?;
            Ok(success(
                "category create",
                json!({"id": id, "category": budget.categories.iter().find(|category| category.id == id).map(category_value), "dry_run":args.dry_run}),
                Some(meta_for_mutation(
                    "category create",
                    &budget,
                    original.requires_migration_writeback,
                    wrote,
                )),
            ))
        }
        CategoryCommand::Update(args) => {
            if args.title.is_none()
                && args.r#type.is_none()
                && args.planned.is_none()
                && args.planned_minor_units.is_none()
                && args.accumulated.is_none()
                && args.accumulated_minor_units.is_none()
                && args.ordinal.is_none()
            {
                return Err(usage_error("Provide at least one category field to update"));
            }
            let planned = money_pair(
                args.planned.as_deref(),
                args.planned_minor_units.as_deref(),
                None,
            )?;
            let accumulated = money_pair(
                args.accumulated.as_deref(),
                args.accumulated_minor_units.as_deref(),
                None,
            )?;
            let new_type = args.r#type.map(category_type);
            let (budget, original, wrote, ()) = mutate(
                &mut context,
                &args.file.file,
                args.if_revision,
                args.dry_run,
                move |budget| {
                    let mut category = budget
                        .categories
                        .iter()
                        .find(|category| category.id == args.id)
                        .cloned()
                        .ok_or_else(|| missing_entity("category", args.id.to_string()))?;
                    if let Some(title) = args.title.clone() {
                        category.title = title;
                    }
                    if let Some(value) = planned {
                        category.amount_planned = value;
                    }
                    if let Some(value) = accumulated {
                        category.amount_accumulated = value;
                    }
                    if let Some(value) = new_type {
                        category.category_type = value;
                    }
                    if let Some(value) = args.ordinal {
                        category.ordinal = i32::try_from(value)
                            .map_err(|_| usage_error("Category ordinal is too large"))?;
                    }
                    let id = category.id;
                    let updated = bw_core::domain::update_category(budget, category)
                        .map_err(|message| core_error("mutation_failed", message))?;
                    if !updated.categories.iter().any(|category| category.id == id) {
                        return Err(missing_entity("category", id.to_string()));
                    }
                    Ok((updated, ()))
                },
            )?;
            let item = budget
                .categories
                .iter()
                .find(|category| category.id == args.id)
                .map(category_value)
                .unwrap_or(Value::Null);
            Ok(success(
                "category update",
                json!({"category":item,"dry_run":args.dry_run}),
                Some(meta_for_mutation(
                    "category update",
                    &budget,
                    original.requires_migration_writeback,
                    wrote,
                )),
            ))
        }
        CategoryCommand::Delete(args) => {
            let (budget, original, wrote, ()) = mutate(
                &mut context,
                &args.entity.file.file,
                args.if_revision,
                args.dry_run,
                |budget| {
                    if !budget
                        .categories
                        .iter()
                        .any(|category| category.id == args.entity.id)
                    {
                        return Err(missing_entity("category", args.entity.id.to_string()));
                    }
                    let updated = bw_core::domain::delete_category(budget, args.entity.id)
                        .map_err(|message| core_error("mutation_failed", message))?;
                    Ok((updated, ()))
                },
            )?;
            Ok(success(
                "category delete",
                json!({"deleted": true, "id": args.entity.id,"dry_run":args.dry_run}),
                Some(meta_for_mutation(
                    "category delete",
                    &budget,
                    original.requires_migration_writeback,
                    wrote,
                )),
            ))
        }
        CategoryCommand::Move(args) => {
            let (budget, original, wrote, ()) = mutate(
                &mut context,
                &args.entity.file.file,
                args.if_revision,
                args.dry_run,
                |budget| {
                    let mut category = budget
                        .categories
                        .iter()
                        .find(|category| category.id == args.entity.id)
                        .cloned()
                        .ok_or_else(|| missing_entity("category", args.entity.id.to_string()))?;
                    category.ordinal = i32::try_from(args.ordinal)
                        .map_err(|_| usage_error("Category ordinal is too large"))?;
                    let updated = bw_core::domain::update_category(budget, category)
                        .map_err(|message| core_error("mutation_failed", message))?;
                    Ok((updated, ()))
                },
            )?;
            let item = budget
                .categories
                .iter()
                .find(|category| category.id == args.entity.id)
                .map(category_value)
                .unwrap_or(Value::Null);
            Ok(success(
                "category move",
                json!({"category":item,"dry_run":args.dry_run}),
                Some(meta_for_mutation(
                    "category move",
                    &budget,
                    original.requires_migration_writeback,
                    wrote,
                )),
            ))
        }
    }
}

fn run_transaction(mut context: Context, command: TransactionCommand) -> Result<Outcome, ApiError> {
    match command {
        TransactionCommand::List(args) => transaction_list(args),
        TransactionCommand::Show(args) => {
            let loaded = storage::load(&args.file.file)?;
            let (category, transaction) = find_transaction(&loaded.budget, args.id)?;
            Ok(success(
                "transaction show",
                transaction_value(transaction, category),
                Some(meta_for_loaded("transaction show", &loaded, false)),
            ))
        }
        TransactionCommand::Create(args) => {
            let amount = money_pair(
                args.amount.as_deref(),
                args.amount_minor_units.as_deref(),
                None,
            )?
            .ok_or_else(|| usage_error("Provide --amount or --amount-minor-units"))?;
            let transaction_date = transaction_date_or_today(args.date.as_deref(), args.today)?;
            let (budget, original, wrote, id) = mutate(
                &mut context,
                &args.file.file,
                args.if_revision,
                args.dry_run,
                move |budget| {
                    if !budget
                        .categories
                        .iter()
                        .any(|category| category.id == args.category_id)
                    {
                        return Err(missing_entity("category", args.category_id.to_string()));
                    }
                    let transaction = bw_core::models::new_transaction(
                        args.title.clone(),
                        Some(args.description.clone()),
                        Some(transaction_date),
                        amount,
                    )
                    .map_err(|message| core_error("mutation_failed", message))?;
                    let id = transaction.id;
                    let updated =
                        bw_core::domain::create_transaction(budget, args.category_id, transaction)
                            .map_err(|message| core_error("mutation_failed", message))?;
                    Ok((updated, id))
                },
            )?;
            let (category, transaction) = find_transaction(&budget, id)?;
            Ok(success(
                "transaction create",
                json!({"transaction":transaction_value(transaction, category),"dry_run":args.dry_run}),
                Some(meta_for_mutation(
                    "transaction create",
                    &budget,
                    original.requires_migration_writeback,
                    wrote,
                )),
            ))
        }
        TransactionCommand::Update(args) => {
            if args.title.is_none()
                && args.description.is_none()
                && args.date.is_none()
                && args.amount.is_none()
                && args.amount_minor_units.is_none()
            {
                return Err(usage_error(
                    "Provide at least one transaction field to update",
                ));
            }
            let date_update = args.date.as_deref().map(date).transpose()?;
            let amount_update = money_pair(
                args.amount.as_deref(),
                args.amount_minor_units.as_deref(),
                None,
            )?;
            let (budget, original, wrote, ()) = mutate(
                &mut context,
                &args.file.file,
                args.if_revision,
                args.dry_run,
                move |budget| {
                    let (category, original_tx) = find_transaction(&budget, args.id)?;
                    let category_id = category.id;
                    let mut transaction = original_tx.clone();
                    if let Some(title) = args.title.clone() {
                        transaction.title = title;
                    }
                    if let Some(description) = args.description.clone() {
                        transaction.description = description;
                    }
                    if let Some(date) = date_update {
                        transaction.date = date;
                    }
                    if let Some(amount) = amount_update {
                        transaction.amount = amount;
                    }
                    let updated =
                        bw_core::domain::update_transaction(budget, category_id, transaction)
                            .map_err(|message| core_error("mutation_failed", message))?;
                    Ok((updated, ()))
                },
            )?;
            let (category, transaction) = find_transaction(&budget, args.id)?;
            Ok(success(
                "transaction update",
                json!({"transaction":transaction_value(transaction, category),"dry_run":args.dry_run}),
                Some(meta_for_mutation(
                    "transaction update",
                    &budget,
                    original.requires_migration_writeback,
                    wrote,
                )),
            ))
        }
        TransactionCommand::Delete(args) => {
            let (budget, original, wrote, ()) = mutate(
                &mut context,
                &args.file.file,
                args.if_revision,
                args.dry_run,
                |budget| {
                    let (category, _) = find_transaction(&budget, args.id)?;
                    let category_id = category.id;
                    let updated = bw_core::domain::delete_transaction(budget, category_id, args.id)
                        .map_err(|message| core_error("mutation_failed", message))?;
                    Ok((updated, ()))
                },
            )?;
            Ok(success(
                "transaction delete",
                json!({"deleted": true, "id": args.id,"dry_run":args.dry_run}),
                Some(meta_for_mutation(
                    "transaction delete",
                    &budget,
                    original.requires_migration_writeback,
                    wrote,
                )),
            ))
        }
        TransactionCommand::Move(args) => {
            let (budget, original, wrote, ()) = mutate(
                &mut context,
                &args.file.file,
                args.if_revision,
                args.dry_run,
                |budget| {
                    let (origin, _) = find_transaction(&budget, args.id)?;
                    let origin_id = origin.id;
                    if !budget
                        .categories
                        .iter()
                        .any(|category| category.id == args.category_id)
                    {
                        return Err(missing_entity("category", args.category_id.to_string()));
                    }
                    let updated = bw_core::domain::move_transaction(
                        budget,
                        origin_id,
                        args.category_id,
                        args.id,
                    )
                    .map_err(|message| core_error("mutation_failed", message))?;
                    Ok((updated, ()))
                },
            )?;
            let (category, transaction) = find_transaction(&budget, args.id)?;
            Ok(success(
                "transaction move",
                json!({"transaction":transaction_value(transaction, category),"dry_run":args.dry_run}),
                Some(meta_for_mutation(
                    "transaction move",
                    &budget,
                    original.requires_migration_writeback,
                    wrote,
                )),
            ))
        }
    }
}

fn transaction_list(args: TransactionListArgs) -> Result<Outcome, ApiError> {
    validate_page(args.limit)?;
    let after = args.after.as_deref().map(date).transpose()?;
    let before = args.before.as_deref().map(date).transpose()?;
    let min_amount = args.min_amount.as_deref().map(money).transpose()?;
    let max_amount = args.max_amount.as_deref().map(money).transpose()?;
    if let (Some(min), Some(max)) = (min_amount, max_amount) {
        if min.value > max.value {
            return Err(usage_error("--min-amount cannot exceed --max-amount"));
        }
    }
    if let (Some(after), Some(before)) = (after, before) {
        if after > before {
            return Err(usage_error("--after cannot be later than --before"));
        }
    }
    let loaded = storage::load(&args.file.file)?;
    if let Some(category_id) = args.category_id {
        if !loaded
            .budget
            .categories
            .iter()
            .any(|category| category.id == category_id)
        {
            return Err(missing_entity("category", category_id.to_string()));
        }
    }
    let search = args.search.as_deref().map(str::to_lowercase);
    let mut rows: Vec<(&BWCategory, &BWTransaction)> = loaded
        .budget
        .categories
        .iter()
        .filter(|category| args.category_id.is_none_or(|id| category.id == id))
        .flat_map(|category| {
            category
                .transactions
                .iter()
                .map(move |transaction| (category, transaction))
        })
        .filter(|(_, transaction)| after.is_none_or(|after| transaction.date >= after))
        .filter(|(_, transaction)| before.is_none_or(|before| transaction.date <= before))
        .filter(|(_, transaction)| {
            min_amount.is_none_or(|min| transaction.amount.value >= min.value)
        })
        .filter(|(_, transaction)| {
            max_amount.is_none_or(|max| transaction.amount.value <= max.value)
        })
        .filter(|(category, transaction)| {
            search.as_ref().is_none_or(|query| {
                transaction.title.to_lowercase().contains(query)
                    || transaction.description.to_lowercase().contains(query)
                    || category.title.to_lowercase().contains(query)
            })
        })
        .collect();
    rows.sort_by(|(category_a, tx_a), (category_b, tx_b)| {
        let primary = match args.sort {
            TransactionSort::Date => tx_a.date.cmp(&tx_b.date),
            TransactionSort::Title => tx_a.title.to_lowercase().cmp(&tx_b.title.to_lowercase()),
            TransactionSort::Amount => tx_a.amount.value.cmp(&tx_b.amount.value),
            TransactionSort::Category => category_a
                .title
                .to_lowercase()
                .cmp(&category_b.title.to_lowercase()),
        };
        primary.then_with(|| tx_a.id.cmp(&tx_b.id))
    });
    let total = rows.len();
    let items: Vec<_> = rows
        .into_iter()
        .skip(args.offset)
        .take(args.limit)
        .map(|(category, transaction)| transaction_value(transaction, category))
        .collect();
    Ok(success(
        "transaction list",
        json!({"items":items,"total":total,"offset":args.offset,"limit":args.limit}),
        Some(meta_for_loaded("transaction list", &loaded, false)),
    ))
}

fn find_transaction(
    budget: &BWBudget,
    id: Uuid,
) -> Result<(&BWCategory, &BWTransaction), ApiError> {
    budget
        .categories
        .iter()
        .find_map(|category| {
            category
                .transactions
                .iter()
                .find(|transaction| transaction.id == id)
                .map(|transaction| (category, transaction))
        })
        .ok_or_else(|| missing_entity("transaction", id.to_string()))
}

fn run_report(command: ReportCommand) -> Result<Outcome, ApiError> {
    let (name, file, mode) = match command {
        ReportCommand::Summary(file) => ("report summary", file.file, None),
        ReportCommand::Allocation(args) => ("report allocation", args.file.file, args.mode),
        ReportCommand::Categories(args) => ("report categories", args.file.file, args.mode),
        ReportCommand::Comparison(file) => ("report comparison", file.file, None),
    };
    let loaded = storage::load(&file)?;
    let summary = bw_core::reporting::build_reporting_summary(&loaded.budget)
        .map_err(|message| core_error("report_failed", message))?;
    let data = match name {
        "report summary" => report_summary_value(&summary),
        "report allocation" => {
            json!({"segments": summary.allocation_segments.iter().filter(|segment| mode.is_none_or(|mode| amount_mode_name(segment.amount_mode) == report_mode_name(mode))).map(|segment| json!({"mode":amount_mode_name(segment.amount_mode),"category_type":category_type_name(segment.category_type),"amount":format_money(segment.amount.value)})).collect::<Vec<_>>()})
        }
        "report categories" => {
            json!({"segments": summary.category_segments.iter().filter(|segment| mode.is_none_or(|mode| amount_mode_name(segment.amount_mode) == report_mode_name(mode))).map(|segment| json!({"mode":amount_mode_name(segment.amount_mode),"category_id":segment.category_id,"category_type":category_type_name(segment.category_type),"title":segment.title,"amount":format_money(segment.amount.value)})).collect::<Vec<_>>()})
        }
        _ => {
            json!({"segments": summary.comparison_segments.iter().map(|segment| json!({"row":comparison_row_name(segment.row),"component":component_name(segment.component),"amount":format_money(segment.amount.value)})).collect::<Vec<_>>()})
        }
    };
    Ok(success(
        name,
        data,
        Some(meta_for_loaded(name, &loaded, false)),
    ))
}

fn report_summary_value(summary: &bw_core::reporting::BWReportingSummary) -> Value {
    let t = &summary.totals;
    json!({"totals":{"income":format_money(t.income.value),"planned_spending":format_money(t.planned_spending.value),"actual_spending":format_money(t.actual_spending.value),"planned_savings":format_money(t.planned_savings.value),"planned_allocation":format_money(t.planned_allocation.value),"actual_allocation":format_money(t.actual_allocation.value),"left_to_budget":format_money(t.left_to_budget)},
      "allocation_segments":summary.allocation_segments.iter().map(|segment| json!({"mode":amount_mode_name(segment.amount_mode),"category_type":category_type_name(segment.category_type),"amount":format_money(segment.amount.value)})).collect::<Vec<_>>(),
      "category_segments":summary.category_segments.iter().map(|segment| json!({"mode":amount_mode_name(segment.amount_mode),"category_id":segment.category_id,"category_type":category_type_name(segment.category_type),"title":segment.title,"amount":format_money(segment.amount.value)})).collect::<Vec<_>>(),
      "comparison_segments":summary.comparison_segments.iter().map(|segment| json!({"row":comparison_row_name(segment.row),"component":component_name(segment.component),"amount":format_money(segment.amount.value)})).collect::<Vec<_>>()})
}

fn amount_mode_name(mode: bw_core::reporting::BWReportingAmountMode) -> &'static str {
    match mode {
        bw_core::reporting::BWReportingAmountMode::Planned => "planned",
        bw_core::reporting::BWReportingAmountMode::Actual => "actual",
    }
}
fn report_mode_name(mode: ReportModeArg) -> &'static str {
    match mode {
        ReportModeArg::Planned => "planned",
        ReportModeArg::Actual => "actual",
    }
}
fn comparison_row_name(row: bw_core::reporting::BWReportingComparisonRow) -> &'static str {
    match row {
        bw_core::reporting::BWReportingComparisonRow::Income => "income",
        bw_core::reporting::BWReportingComparisonRow::Planned => "planned",
        bw_core::reporting::BWReportingComparisonRow::Actual => "actual",
    }
}
fn component_name(component: bw_core::reporting::BWReportingComponent) -> &'static str {
    match component {
        bw_core::reporting::BWReportingComponent::Income => "income",
        bw_core::reporting::BWReportingComponent::Expenses => "expenses",
        bw_core::reporting::BWReportingComponent::Savings => "savings",
        bw_core::reporting::BWReportingComponent::Debt => "debt",
    }
}

pub(crate) fn transaction_date_or_today(
    date_value: Option<&str>,
    today: bool,
) -> Result<BWDate, ApiError> {
    match (date_value, today) {
        (Some(value), false) => date(value),
        (None, true) => {
            let today = Local::now().date_naive();
            Ok(BWDate {
                year: today.year(),
                month: today.month() as i32,
                day: today.day() as i32,
            })
        }
        _ => Err(usage_error(
            "Provide exactly one of --date YYYY-MM-DD or --today",
        )),
    }
}
