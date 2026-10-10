use std::path::PathBuf;

use clap::{Parser, Subcommand, ValueEnum};
use uuid::Uuid;

#[derive(Debug, Clone, Copy, PartialEq, Eq, ValueEnum)]
pub enum OutputFormat {
    Json,
    Text,
}

#[derive(Debug, Parser)]
#[command(
    name = "budget-warden",
    version,
    about = "Manage portable Budget Warden files"
)]
pub struct Cli {
    #[arg(long, global = true, value_enum, default_value = "json")]
    pub output: OutputFormat,
    #[arg(long, global = true, value_name = "DIR")]
    pub config_dir: Option<PathBuf>,
    #[arg(long, global = true, value_name = "UUID")]
    pub device_id: Option<Uuid>,
    #[command(subcommand)]
    pub command: Command,
}

#[derive(Debug, Subcommand)]
pub enum Command {
    Capabilities,
    Budget {
        #[command(subcommand)]
        command: BudgetCommand,
    },
    Template {
        #[command(subcommand)]
        command: TemplateCommand,
    },
    Category {
        #[command(subcommand)]
        command: CategoryCommand,
    },
    Transaction {
        #[command(subcommand)]
        command: TransactionCommand,
    },
    Report {
        #[command(subcommand)]
        command: ReportCommand,
    },
    Config {
        #[command(subcommand)]
        command: ConfigCommand,
    },
    Recent {
        #[command(subcommand)]
        command: RecentCommand,
    },
    Apply(ApplyArgs),
}

#[derive(Debug, Subcommand)]
pub enum BudgetCommand {
    Create(BudgetCreateArgs),
    Show(FileArgs),
    Rename(BudgetRenameArgs),
    Copy(BudgetCopyArgs),
    Move(BudgetMoveArgs),
    Delete(BudgetDeleteArgs),
    Validate(FileArgs),
    Migrate(BudgetMigrateArgs),
    Merge(BudgetMergeArgs),
    List(BudgetListArgs),
}

#[derive(Debug, clap::Args)]
pub struct FileArgs {
    #[arg(long, value_name = "PATH")]
    pub file: PathBuf,
}

#[derive(Debug, clap::Args)]
pub struct BudgetCreateArgs {
    #[arg(long, value_name = "PATH")]
    pub file: PathBuf,
    #[arg(long)]
    pub title: String,
    #[arg(long, value_name = "ID", conflicts_with = "from")]
    pub template: Option<String>,
    #[arg(long, value_name = "PATH", conflicts_with = "template")]
    pub from: Option<PathBuf>,
    #[arg(long, value_name = "UUID")]
    pub overwrite_budget_id: Option<Uuid>,
    #[arg(long)]
    pub dry_run: bool,
}

#[derive(Debug, clap::Args)]
pub struct BudgetRenameArgs {
    #[command(flatten)]
    pub file: FileArgs,
    #[arg(long)]
    pub title: String,
    #[arg(long, value_name = "UUID")]
    pub if_revision: Option<Uuid>,
    #[arg(long)]
    pub dry_run: bool,
}

#[derive(Debug, clap::Args)]
pub struct BudgetCopyArgs {
    #[command(flatten)]
    pub file: FileArgs,
    #[arg(long, value_name = "PATH")]
    pub to: PathBuf,
    #[arg(long, value_name = "UUID")]
    pub overwrite_budget_id: Option<Uuid>,
    #[arg(long)]
    pub dry_run: bool,
}

#[derive(Debug, clap::Args)]
pub struct BudgetMoveArgs {
    #[command(flatten)]
    pub file: FileArgs,
    #[arg(long, value_name = "PATH")]
    pub to: PathBuf,
    #[arg(long, value_name = "UUID")]
    pub overwrite_budget_id: Option<Uuid>,
    #[arg(long, value_name = "UUID")]
    pub if_revision: Option<Uuid>,
    #[arg(long)]
    pub dry_run: bool,
}

#[derive(Debug, clap::Args)]
pub struct BudgetDeleteArgs {
    #[command(flatten)]
    pub file: FileArgs,
    #[arg(long, value_name = "UUID")]
    pub confirm_budget_id: Uuid,
    #[arg(long, value_name = "UUID")]
    pub if_revision: Option<Uuid>,
    #[arg(long)]
    pub dry_run: bool,
}

#[derive(Debug, clap::Args)]
pub struct BudgetMigrateArgs {
    #[arg(long, value_name = "PATH")]
    pub file: PathBuf,
    #[arg(long, value_name = "PATH", conflicts_with = "in_place")]
    pub to: Option<PathBuf>,
    #[arg(long, conflicts_with = "to")]
    pub in_place: bool,
    #[arg(long, value_name = "UUID")]
    pub overwrite_budget_id: Option<Uuid>,
    #[arg(long, value_name = "UUID")]
    pub if_revision: Option<Uuid>,
    #[arg(long)]
    pub dry_run: bool,
}

#[derive(Debug, clap::Args)]
pub struct BudgetMergeArgs {
    #[command(flatten)]
    pub file: FileArgs,
    #[arg(long, value_name = "PATH")]
    pub other: PathBuf,
    #[arg(long, value_name = "PATH")]
    pub to: Option<PathBuf>,
    #[arg(long, value_name = "UUID")]
    pub if_revision: Option<Uuid>,
    #[arg(long)]
    pub dry_run: bool,
}

#[derive(Debug, clap::Args)]
pub struct BudgetListArgs {
    #[arg(long, value_name = "DIR")]
    pub directory: PathBuf,
}

#[derive(Debug, Subcommand)]
pub enum TemplateCommand {
    List,
    Show {
        #[arg(value_name = "ID")]
        template: String,
    },
}

#[derive(Debug, Subcommand)]
pub enum CategoryCommand {
    List(CategoryListArgs),
    Show(EntityArgs),
    Create(CategoryCreateArgs),
    Update(CategoryUpdateArgs),
    Delete(CategoryDeleteArgs),
    Move(CategoryMoveArgs),
}

#[derive(Debug, clap::Args)]
pub struct EntityArgs {
    #[command(flatten)]
    pub file: FileArgs,
    #[arg(long, value_name = "UUID")]
    pub id: Uuid,
}

#[derive(Debug, Clone, Copy, ValueEnum)]
pub enum CategoryTypeArg {
    Income,
    Expenses,
    Savings,
    Debt,
}

#[derive(Debug, Clone, Copy, ValueEnum)]
pub enum SortOrder {
    Title,
    Ordinal,
    Planned,
    Actual,
}

#[derive(Debug, clap::Args)]
pub struct CategoryListArgs {
    #[command(flatten)]
    pub file: FileArgs,
    #[arg(long, value_enum)]
    pub r#type: Option<CategoryTypeArg>,
    #[arg(long)]
    pub search: Option<String>,
    #[arg(long, value_enum, default_value = "ordinal")]
    pub sort: SortOrder,
    #[arg(long, default_value_t = 0)]
    pub offset: usize,
    #[arg(long, default_value_t = 100)]
    pub limit: usize,
}

#[derive(Debug, clap::Args)]
pub struct CategoryCreateArgs {
    #[command(flatten)]
    pub file: FileArgs,
    #[arg(long)]
    pub title: String,
    #[arg(long, value_enum, name = "type")]
    pub r#type: CategoryTypeArg,
    #[arg(long, allow_hyphen_values = true)]
    pub planned: Option<String>,
    #[arg(long, value_name = "INTEGER", allow_hyphen_values = true)]
    pub planned_minor_units: Option<String>,
    #[arg(long, allow_hyphen_values = true)]
    pub accumulated: Option<String>,
    #[arg(long, value_name = "INTEGER", allow_hyphen_values = true)]
    pub accumulated_minor_units: Option<String>,
    #[arg(long)]
    pub ordinal: Option<usize>,
    #[arg(long, value_name = "UUID")]
    pub if_revision: Option<Uuid>,
    #[arg(long)]
    pub dry_run: bool,
}

#[derive(Debug, clap::Args)]
pub struct CategoryUpdateArgs {
    #[command(flatten)]
    pub file: FileArgs,
    #[arg(long, value_name = "UUID")]
    pub id: Uuid,
    #[arg(long)]
    pub title: Option<String>,
    #[arg(long, value_enum, name = "type")]
    pub r#type: Option<CategoryTypeArg>,
    #[arg(long, allow_hyphen_values = true)]
    pub planned: Option<String>,
    #[arg(long, value_name = "INTEGER", allow_hyphen_values = true)]
    pub planned_minor_units: Option<String>,
    #[arg(long, allow_hyphen_values = true)]
    pub accumulated: Option<String>,
    #[arg(long, value_name = "INTEGER", allow_hyphen_values = true)]
    pub accumulated_minor_units: Option<String>,
    #[arg(long)]
    pub ordinal: Option<usize>,
    #[arg(long, value_name = "UUID")]
    pub if_revision: Option<Uuid>,
    #[arg(long)]
    pub dry_run: bool,
}

#[derive(Debug, clap::Args)]
pub struct CategoryDeleteArgs {
    #[command(flatten)]
    pub entity: EntityArgs,
    #[arg(long, value_name = "UUID")]
    pub if_revision: Option<Uuid>,
    #[arg(long)]
    pub dry_run: bool,
}
#[derive(Debug, clap::Args)]
pub struct CategoryMoveArgs {
    #[command(flatten)]
    pub entity: EntityArgs,
    #[arg(long)]
    pub ordinal: usize,
    #[arg(long, value_name = "UUID")]
    pub if_revision: Option<Uuid>,
    #[arg(long)]
    pub dry_run: bool,
}

#[derive(Debug, Subcommand)]
pub enum TransactionCommand {
    List(TransactionListArgs),
    Show(TransactionShowArgs),
    Create(TransactionCreateArgs),
    Update(TransactionUpdateArgs),
    Delete(TransactionDeleteArgs),
    Move(TransactionMoveArgs),
}

#[derive(Debug, clap::Args)]
pub struct TransactionListArgs {
    #[command(flatten)]
    pub file: FileArgs,
    #[arg(long, value_name = "UUID")]
    pub category_id: Option<Uuid>,
    #[arg(long)]
    pub search: Option<String>,
    #[arg(long)]
    pub after: Option<String>,
    #[arg(long)]
    pub before: Option<String>,
    #[arg(long, allow_hyphen_values = true)]
    pub min_amount: Option<String>,
    #[arg(long, allow_hyphen_values = true)]
    pub max_amount: Option<String>,
    #[arg(long, value_enum, default_value = "date")]
    pub sort: TransactionSort,
    #[arg(long, default_value_t = 0)]
    pub offset: usize,
    #[arg(long, default_value_t = 100)]
    pub limit: usize,
}

#[derive(Debug, Clone, Copy, ValueEnum)]
pub enum TransactionSort {
    Date,
    Title,
    Amount,
    Category,
}

#[derive(Debug, clap::Args)]
pub struct TransactionShowArgs {
    #[command(flatten)]
    pub file: FileArgs,
    #[arg(long, value_name = "UUID")]
    pub id: Uuid,
}
#[derive(Debug, clap::Args)]
pub struct TransactionCreateArgs {
    #[command(flatten)]
    pub file: FileArgs,
    #[arg(long, value_name = "UUID")]
    pub category_id: Uuid,
    #[arg(long)]
    pub title: String,
    #[arg(long, default_value = "")]
    pub description: String,
    #[arg(long, conflicts_with = "today")]
    pub date: Option<String>,
    #[arg(long)]
    pub today: bool,
    #[arg(long, allow_hyphen_values = true)]
    pub amount: Option<String>,
    #[arg(long, value_name = "INTEGER", allow_hyphen_values = true)]
    pub amount_minor_units: Option<String>,
    #[arg(long, value_name = "UUID")]
    pub if_revision: Option<Uuid>,
    #[arg(long)]
    pub dry_run: bool,
}
#[derive(Debug, clap::Args)]
pub struct TransactionUpdateArgs {
    #[command(flatten)]
    pub file: FileArgs,
    #[arg(long, value_name = "UUID")]
    pub id: Uuid,
    #[arg(long)]
    pub title: Option<String>,
    #[arg(long)]
    pub description: Option<String>,
    #[arg(long)]
    pub date: Option<String>,
    #[arg(long, allow_hyphen_values = true)]
    pub amount: Option<String>,
    #[arg(long, value_name = "INTEGER", allow_hyphen_values = true)]
    pub amount_minor_units: Option<String>,
    #[arg(long, value_name = "UUID")]
    pub if_revision: Option<Uuid>,
    #[arg(long)]
    pub dry_run: bool,
}
#[derive(Debug, clap::Args)]
pub struct TransactionDeleteArgs {
    #[command(flatten)]
    pub file: FileArgs,
    #[arg(long, value_name = "UUID")]
    pub id: Uuid,
    #[arg(long, value_name = "UUID")]
    pub if_revision: Option<Uuid>,
    #[arg(long)]
    pub dry_run: bool,
}
#[derive(Debug, clap::Args)]
pub struct TransactionMoveArgs {
    #[command(flatten)]
    pub file: FileArgs,
    #[arg(long, value_name = "UUID")]
    pub id: Uuid,
    #[arg(long, value_name = "UUID")]
    pub category_id: Uuid,
    #[arg(long, value_name = "UUID")]
    pub if_revision: Option<Uuid>,
    #[arg(long)]
    pub dry_run: bool,
}

#[derive(Debug, Subcommand)]
pub enum ReportCommand {
    Summary(FileArgs),
    Allocation(ReportArgs),
    Categories(ReportArgs),
    Comparison(FileArgs),
}
#[derive(Debug, clap::Args)]
pub struct ReportArgs {
    #[command(flatten)]
    pub file: FileArgs,
    #[arg(long, value_enum)]
    pub mode: Option<ReportModeArg>,
}
#[derive(Debug, Clone, Copy, ValueEnum)]
pub enum ReportModeArg {
    Planned,
    Actual,
}

#[derive(Debug, Subcommand)]
pub enum ConfigCommand {
    Show,
    Set {
        #[arg(long)]
        currency: String,
    },
    Paths,
}
#[derive(Debug, Subcommand)]
pub enum RecentCommand {
    List,
    Add {
        #[arg(value_name = "PATH")]
        file: PathBuf,
    },
    Remove {
        #[arg(value_name = "PATH")]
        file: PathBuf,
    },
}

#[derive(Debug, clap::Args)]
pub struct ApplyArgs {
    #[arg(long, value_name = "FILE|-", required = true)]
    pub input: String,
    #[arg(long)]
    pub dry_run: bool,
    #[arg(long, value_name = "UUID")]
    pub if_revision: Option<Uuid>,
}
