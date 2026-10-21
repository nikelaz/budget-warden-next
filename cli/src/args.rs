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
    /// Budgets stored in Google Drive.
    Cloud {
        #[command(subcommand)]
        command: CloudCommand,
    },
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

#[derive(Debug, Subcommand)]
pub enum CloudCommand {
    /// Shows whether Google Drive is configured and signed in.
    Status,
    /// Signs in to Google Drive in the browser.
    SignIn(CloudSignInArgs),
    /// Signs out and removes local working copies of cloud budgets.
    SignOut,
    /// Lists budgets in Google Drive: yours and those you added.
    List(CloudListArgs),
    /// Chooses budgets someone shared with you in the browser and adds them.
    AddShared(CloudSignInArgs),
    /// Downloads or syncs a cloud budget and prints its local working copy.
    Sync(CloudSyncArgs),
    /// Uploads a local budget to Google Drive as a new cloud budget.
    Upload(CloudUploadArgs),
    /// Shares a cloud budget with someone by email.
    Share(CloudShareArgs),
    /// Lists who can access a cloud budget.
    Shares(CloudIdArgs),
    /// Revokes someone's access to a cloud budget.
    Unshare(CloudUnshareArgs),
}

#[derive(Debug, clap::Args)]
pub struct CloudSignInArgs {
    /// Print the sign-in URL instead of opening a browser.
    #[arg(long)]
    pub no_browser: bool,
    #[arg(long, value_name = "SECONDS", default_value_t = 300)]
    pub timeout: i32,
}

#[derive(Debug, clap::Args)]
pub struct CloudListArgs {
    /// List budgets from the last listing without contacting Google Drive.
    #[arg(long)]
    pub offline: bool,
}

#[derive(Debug, clap::Args)]
#[group(required = true, multiple = false)]
pub struct CloudSyncArgs {
    /// Drive file ID from `cloud list`.
    #[arg(long, value_name = "ID")]
    pub id: Option<String>,
    /// A working copy previously returned by `cloud sync`.
    #[arg(long, value_name = "PATH")]
    pub file: Option<PathBuf>,
}

#[derive(Debug, clap::Args)]
pub struct CloudUploadArgs {
    #[arg(long, value_name = "PATH")]
    pub file: PathBuf,
    /// File name in Google Drive; defaults to the local file name.
    #[arg(long, value_name = "NAME")]
    pub name: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, ValueEnum)]
pub enum CloudRoleArg {
    Writer,
    Reader,
}

#[derive(Debug, clap::Args)]
pub struct CloudShareArgs {
    #[arg(long, value_name = "ID")]
    pub id: String,
    #[arg(long, value_name = "EMAIL")]
    pub email: String,
    #[arg(long, value_enum, default_value = "writer")]
    pub role: CloudRoleArg,
    /// Note included in Google's invitation email.
    #[arg(long, value_name = "TEXT")]
    pub message: Option<String>,
}

#[derive(Debug, clap::Args)]
pub struct CloudIdArgs {
    #[arg(long, value_name = "ID")]
    pub id: String,
}

#[derive(Debug, clap::Args)]
pub struct CloudUnshareArgs {
    #[arg(long, value_name = "ID")]
    pub id: String,
    /// Share ID from `cloud shares`.
    #[arg(long, value_name = "SHARE_ID")]
    pub share_id: String,
}
