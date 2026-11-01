use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::{Mutex, MutexGuard, OnceLock};

use bw_core::app_state::initialize_core;
use bw_core::codec::{decode_budget, encode_budget};
use bw_core::domain;
use bw_core::models::{BWBudget, BWCategory, BWCategoryType, BWDate, BWMoneyAmount, BWTransaction};
use bw_core::reporting::{BWReportingSummary, build_reporting_summary};
use bw_core::templates::{
    BWTemplateType, budget_from_previous_budget, budget_from_template, budget_from_template_id,
};
use chrono::{Datelike, Local, NaiveDate};
use iso_currency::{Country, Currency, IntoEnumIterator};
use uuid::Uuid;

const APP_DIR: &str = "budget-warden";
static CURRENCIES: OnceLock<Vec<CurrencyInfo>> = OnceLock::new();
/// Held for the whole read-merge-write of every budget save, by the app and
/// by the MCP server, so neither can overwrite a save it never read.
static BUDGET_SAVE_LOCK: Mutex<()> = Mutex::new(());

pub(crate) fn budget_save_lock() -> MutexGuard<'static, ()> {
    BUDGET_SAVE_LOCK
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

#[derive(Clone, Debug)]
pub struct CurrencyInfo {
    pub code: String,
    pub symbol: String,
    pub name: String,
}

pub fn supported_currencies() -> &'static [CurrencyInfo] {
    CURRENCIES
        .get_or_init(|| {
            let mut currencies = Currency::iter()
                .filter(|currency| {
                    !currency.is_fund()
                        && !currency.is_special()
                        && currency.is_superseded().is_none()
                })
                .map(|currency| CurrencyInfo {
                    code: currency.code().to_string(),
                    symbol: currency.symbol().to_string(),
                    name: currency.name().to_string(),
                })
                .collect::<Vec<_>>();
            currencies.sort_by(|left, right| left.name.cmp(&right.name));
            currencies
        })
        .as_slice()
}

#[derive(Clone, Debug)]
pub enum BudgetTemplate {
    BasicMonthly,
    Empty,
    BuiltIn(String),
    Previous(PathBuf),
}

pub struct AppState {
    settings_dir: PathBuf,
    pub budget: Option<BWBudget>,
    pub recent_files: Vec<PathBuf>,
    pub currency: String,
    pub page: AppPage,
    pub report_mode: ReportMode,
    /// The open budget was saved since the UI last checked, so a cloud
    /// budget needs to sync.
    saved_since_sync: bool,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AppPage {
    Budget,
    Reporting,
    Transactions,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ReportMode {
    Planned,
    Actual,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TransactionSort {
    Newest,
    Oldest,
    AmountHigh,
    AmountLow,
    Title,
    Category,
    Description,
}

impl AppState {
    pub fn new() -> Result<Self, String> {
        let config_dir = config_dir();
        fs::create_dir_all(&config_dir)
            .map_err(|error| format!("Could not create configuration directory: {error}"))?;
        let device_path = config_dir.join("device-id");
        let device_id = fs::read_to_string(&device_path)
            .ok()
            .and_then(|value| Uuid::parse_str(value.trim()).ok())
            .unwrap_or_else(Uuid::new_v4);
        fs::write(&device_path, device_id.to_string())
            .map_err(|error| format!("Could not save device identity: {error}"))?;
        if let Err(error) = initialize_core(device_id)
            && error != "Rust core is already initialized"
        {
            return Err(error);
        }

        let currency_path = config_dir.join("currency");
        let currency = fs::read_to_string(currency_path)
            .ok()
            .map(|value| value.trim().to_uppercase())
            .filter(|value| {
                supported_currencies()
                    .iter()
                    .any(|currency| currency.code == *value)
            })
            .unwrap_or_else(default_currency);
        let recent_files = load_recent_files(&config_dir.join("recent-files"));

        Ok(Self {
            settings_dir: config_dir,
            budget: None,
            recent_files,
            currency,
            page: AppPage::Budget,
            report_mode: ReportMode::Planned,
            saved_since_sync: false,
        })
    }

    pub fn set_currency(&mut self, code: String) -> Result<(), String> {
        if !supported_currencies()
            .iter()
            .any(|currency| currency.code == code)
        {
            return Err("Choose a supported ISO currency.".to_string());
        }
        fs::write(self.settings_dir.join("currency"), &code)
            .map_err(|error| format!("Could not save currency preference: {error}"))?;
        self.currency = code;
        Ok(())
    }

    pub fn open_budget(&mut self, path: &Path) -> Result<(), String> {
        let path = absolute_path(path)?;
        let budget = read_budget(&path)?;
        self.budget = Some(budget);
        self.page = AppPage::Budget;
        self.remember_recent(path);
        Ok(())
    }

    pub fn create_budget(
        &mut self,
        title: &str,
        template: &BudgetTemplate,
        path: &Path,
    ) -> Result<(), String> {
        let path = absolute_path(path)?;
        if path.exists() {
            return Err("A file already exists at that location.".to_string());
        }
        let mut budget = new_budget(title, template)?;
        budget.url = Some(path.to_string_lossy().into_owned());
        write_budget_exclusive(&budget, &path)?;
        self.budget = Some(budget);
        self.page = AppPage::Budget;
        self.remember_recent(path);
        Ok(())
    }

    /// Encodes a new budget that is not saved anywhere yet, for uploading.
    pub fn new_budget_json(&self, title: &str, template: &BudgetTemplate) -> Result<String, String> {
        encode_budget(&new_budget(title, template)?)
    }

    /// Whether the open budget was saved since the last call.
    pub fn take_saved_since_sync(&mut self) -> bool {
        std::mem::take(&mut self.saved_since_sync)
    }

    pub fn category(&self, id: Uuid) -> Option<BWCategory> {
        self.budget
            .as_ref()?
            .categories
            .iter()
            .find(|category| category.id == id)
            .cloned()
    }

    pub fn transaction(&self, id: Uuid) -> Option<(Uuid, BWTransaction)> {
        self.budget
            .as_ref()?
            .categories
            .iter()
            .find_map(|category| {
                category
                    .transactions
                    .iter()
                    .find(|transaction| transaction.id == id)
                    .map(|transaction| (category.id, transaction.clone()))
            })
    }

    pub fn reporting_summary(&self) -> Result<BWReportingSummary, String> {
        let budget = self
            .budget
            .as_ref()
            .ok_or_else(|| "No budget is open.".to_string())?;
        build_reporting_summary(budget)
    }

    pub fn create_category(
        &mut self,
        title: &str,
        amount: i64,
        category_type: BWCategoryType,
    ) -> Result<(), String> {
        let budget = self
            .budget
            .as_ref()
            .ok_or_else(|| "No budget is open.".to_string())?
            .clone();
        let ordinal = budget
            .categories
            .iter()
            .filter(|category| category.category_type == category_type)
            .count() as i32;
        let category = BWCategory {
            id: Uuid::new_v4(),
            ordinal,
            title: title.trim().to_string(),
            amount_planned: BWMoneyAmount { value: amount },
            amount_actual: BWMoneyAmount { value: 0 },
            amount_accumulated: BWMoneyAmount { value: 0 },
            category_type,
            transactions: Vec::new(),
        };
        self.mutate(|budget| domain::create_category(budget, category))
    }

    pub fn update_category(&mut self, category: BWCategory) -> Result<(), String> {
        let budget = self
            .budget
            .as_ref()
            .ok_or_else(|| "No budget is open.".to_string())?;
        let mut updated = category;
        if let Some(current) = budget.categories.iter().find(|item| item.id == updated.id) {
            updated.ordinal = current.ordinal;
            updated.transactions = current.transactions.clone();
            updated.amount_actual = current.amount_actual;
        }
        self.mutate(|budget| domain::update_category(budget, updated))
    }

    pub fn move_category(&mut self, id: Uuid, offset: i32) -> Result<(), String> {
        let budget = self
            .budget
            .as_ref()
            .ok_or_else(|| "No budget is open.".to_string())?
            .clone();
        let category = budget
            .categories
            .iter()
            .find(|category| category.id == id)
            .ok_or_else(|| "Category no longer exists.".to_string())?;
        let mut categories = budget.ordered_categories(Some(category.category_type));
        let index = categories
            .iter()
            .position(|item| item.id == id)
            .ok_or_else(|| "Category no longer exists.".to_string())?;
        let target = index as i32 + offset;
        if target < 0 || target >= categories.len() as i32 {
            return Ok(());
        }
        let mut updated = categories.remove(index);
        updated.ordinal = target;
        self.mutate(|budget| domain::update_category(budget, updated))
    }

    pub fn delete_category(&mut self, id: Uuid) -> Result<(), String> {
        self.mutate(|budget| domain::delete_category(budget, id))
    }

    pub fn create_transaction(
        &mut self,
        category_id: Uuid,
        title: &str,
        description: &str,
        date: NaiveDate,
        amount: i64,
    ) -> Result<(), String> {
        self.budget
            .as_ref()
            .ok_or_else(|| "No budget is open.".to_string())?;
        let transaction = BWTransaction {
            id: Uuid::new_v4(),
            title: title.trim().to_string(),
            description: description.trim().to_string(),
            date: BWDate {
                year: date.year(),
                month: date.month() as i32,
                day: date.day() as i32,
            },
            amount: BWMoneyAmount { value: amount },
        };
        self.mutate(|budget| domain::create_transaction(budget, category_id, transaction))
    }

    pub fn save_transaction(
        &mut self,
        category_id: Uuid,
        target_category_id: Uuid,
        transaction: BWTransaction,
    ) -> Result<(), String> {
        self.mutate(|budget| {
            let id = transaction.id;
            let budget = domain::update_transaction(budget, category_id, transaction)?;
            domain::move_transaction(budget, category_id, target_category_id, id)
        })
    }

    pub fn delete_transaction(
        &mut self,
        category_id: Uuid,
        transaction_id: Uuid,
    ) -> Result<(), String> {
        self.mutate(|budget| domain::delete_transaction(budget, category_id, transaction_id))
    }

    fn mutate<F>(&mut self, operation: F) -> Result<(), String>
    where
        F: FnOnce(BWBudget) -> Result<BWBudget, String>,
    {
        let current = self
            .budget
            .as_ref()
            .ok_or_else(|| "No budget is open.".to_string())?
            .clone();
        let mut updated = operation(current)?.update_actuals()?;
        let path = updated
            .url
            .clone()
            .ok_or_else(|| "Save the budget before making changes.".to_string())?;
        let path = PathBuf::from(path);
        let _save = budget_save_lock();
        let on_disk = read_budget(&path)?;
        updated = domain::merge_budget_for_save(updated, on_disk)?.update_actuals()?;
        updated.url = Some(path.to_string_lossy().into_owned());
        write_budget(&updated, &path)?;
        self.budget = Some(updated);
        self.saved_since_sync = true;
        self.remember_recent(path);
        Ok(())
    }

    pub fn settings_dir(&self) -> &Path {
        &self.settings_dir
    }

    /// Re-reads the open budget after another writer, such as the MCP server,
    /// changed its file.
    pub fn reload_budget(&mut self) -> Result<(), String> {
        let Some(path) = self.budget.as_ref().and_then(|budget| budget.url.clone()) else {
            return Ok(());
        };
        self.budget = Some(read_budget(Path::new(&path))?);
        Ok(())
    }

    pub fn remember_recent(&mut self, path: PathBuf) {
        self.recent_files.retain(|recent| recent != &path);
        self.recent_files.insert(0, path);
        self.recent_files.truncate(12);
        let encoded = self
            .recent_files
            .iter()
            .map(|path| path.to_string_lossy())
            .collect::<Vec<_>>()
            .join("\n");
        if let Err(error) = fs::write(self.settings_dir.join("recent-files"), encoded) {
            eprintln!("Could not save recent budgets: {error}");
        }
    }
}

fn new_budget(title: &str, template: &BudgetTemplate) -> Result<BWBudget, String> {
    let title = title.trim();
    if title.is_empty() {
        return Err("Enter a budget title.".to_string());
    }
    Ok(match template {
        BudgetTemplate::BasicMonthly => {
            budget_from_template(BWTemplateType::BasicMonthly, title.to_string())
        }
        BudgetTemplate::Empty => budget_from_template(BWTemplateType::Empty, title.to_string()),
        BudgetTemplate::BuiltIn(template_id) => {
            budget_from_template_id(template_id.clone(), title.to_string())?
        }
        BudgetTemplate::Previous(previous_path) => {
            let previous = read_budget(previous_path)?;
            budget_from_previous_budget(previous, title.to_string())?
        }
    })
}

pub fn read_budget(path: &Path) -> Result<BWBudget, String> {
    let path = absolute_path(path)?;
    let json = fs::read_to_string(&path)
        .map_err(|error| format!("Could not read {}: {error}", path.display()))?;
    let mut budget = decode_budget(&json, path.to_string_lossy().into_owned())?;
    if budget.requires_migration_writeback {
        write_budget(&budget, &path)?;
        budget.requires_migration_writeback = false;
    }
    Ok(budget)
}

fn write_budget(budget: &BWBudget, path: &Path) -> Result<(), String> {
    write_budget_file(budget, path, false)
}

fn write_budget_exclusive(budget: &BWBudget, path: &Path) -> Result<(), String> {
    write_budget_file(budget, path, true)
}

fn write_budget_file(budget: &BWBudget, path: &Path, exclusive: bool) -> Result<(), String> {
    write_json_file(&encode_budget(budget)?, path, exclusive)
}

/// Atomically replaces the budget at `path` with already-encoded JSON.
pub(crate) fn write_budget_json(encoded: &str, path: &Path) -> Result<(), String> {
    write_json_file(encoded, path, false)
}

/// Writes already-encoded JSON to a new budget file without replacing one.
pub(crate) fn write_budget_json_exclusive(encoded: &str, path: &Path) -> Result<(), String> {
    write_json_file(encoded, path, true)
}

fn write_json_file(encoded: &str, path: &Path, exclusive: bool) -> Result<(), String> {
    let parent = path
        .parent()
        .ok_or_else(|| "The budget path has no parent directory.".to_string())?;
    fs::create_dir_all(parent)
        .map_err(|error| format!("Could not create budget directory: {error}"))?;
    let file_name = path
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("budget.budget");
    let temp_path = parent.join(format!(".{file_name}.{}.tmp", Uuid::new_v4()));
    let result = (|| {
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&temp_path)
            .map_err(|error| format!("Could not create temporary budget file: {error}"))?;
        if let Ok(metadata) = fs::metadata(path) {
            file.set_permissions(metadata.permissions())
                .map_err(|error| format!("Could not preserve budget permissions: {error}"))?;
        }
        file.write_all(encoded.as_bytes())
            .map_err(|error| format!("Could not write budget: {error}"))?;
        file.sync_all()
            .map_err(|error| format!("Could not flush budget to disk: {error}"))?;
        if exclusive {
            // Atomically publish without replacing a file created since the chooser opened.
            if fs::hard_link(&temp_path, path).is_err() {
                // Removable filesystems may not support hard links. create_new still
                // guarantees that an existing budget cannot be overwritten.
                let mut destination = OpenOptions::new()
                    .write(true)
                    .create_new(true)
                    .open(path)
                    .map_err(|error| format!("Could not create budget: {error}"))?;
                if let Err(error) = destination
                    .write_all(encoded.as_bytes())
                    .and_then(|_| destination.sync_all())
                {
                    let _ = fs::remove_file(path);
                    return Err(format!("Could not write new budget: {error}"));
                }
            }
            let _ = fs::remove_file(&temp_path);
        } else {
            fs::rename(&temp_path, path)
                .map_err(|error| format!("Could not save budget: {error}"))?;
        }
        Ok(())
    })();
    if result.is_err() {
        let _ = fs::remove_file(temp_path);
    }
    result
}

fn absolute_path(path: &Path) -> Result<PathBuf, String> {
    // Resolve existing links so atomic saves update their target, not the link itself.
    match fs::canonicalize(path) {
        Ok(path) => return Ok(path),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => (),
        Err(error) => return Err(format!("Could not resolve budget path: {error}")),
    }
    if path.is_absolute() {
        Ok(path.to_path_buf())
    } else {
        std::env::current_dir()
            .map(|current| current.join(path))
            .map_err(|error| format!("Could not resolve budget path: {error}"))
    }
}

fn config_dir() -> PathBuf {
    std::env::var_os("XDG_CONFIG_HOME")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|home| PathBuf::from(home).join(".config")))
        .unwrap_or_else(std::env::temp_dir)
        .join(APP_DIR)
}

fn load_recent_files(path: &Path) -> Vec<PathBuf> {
    fs::read_to_string(path)
        .ok()
        .into_iter()
        .flat_map(|contents| contents.lines().map(PathBuf::from).collect::<Vec<_>>())
        .filter(|path| path.is_file())
        .take(12)
        .collect()
}

pub fn today_text() -> String {
    Local::now().date_naive().format("%Y-%m-%d").to_string()
}

pub fn parse_date(text: &str) -> Option<NaiveDate> {
    NaiveDate::parse_from_str(text.trim(), "%Y-%m-%d").ok()
}

pub fn category_date_range(category: &BWCategory) -> (String, String) {
    let dates = category
        .transactions
        .iter()
        .filter_map(|transaction| {
            NaiveDate::from_ymd_opt(
                transaction.date.year,
                transaction.date.month as u32,
                transaction.date.day as u32,
            )
        })
        .collect::<Vec<_>>();
    date_range_from(dates)
}

pub fn budget_date_range(budget: &BWBudget) -> (String, String) {
    let dates = budget
        .categories
        .iter()
        .flat_map(|category| category.transactions.iter())
        .filter_map(|transaction| {
            NaiveDate::from_ymd_opt(
                transaction.date.year,
                transaction.date.month as u32,
                transaction.date.day as u32,
            )
        })
        .collect::<Vec<_>>();
    date_range_from(dates)
}

fn date_range_from(dates: Vec<NaiveDate>) -> (String, String) {
    match (dates.iter().min(), dates.iter().max()) {
        (Some(start), Some(end)) => (
            start.format("%Y-%m-%d").to_string(),
            end.format("%Y-%m-%d").to_string(),
        ),
        _ => {
            let today = today_text();
            (today.clone(), today)
        }
    }
}

pub fn parse_money(text: &str) -> Option<i64> {
    bw_core::money::parse_money_amount(text.to_string(), None).map(|amount| amount.value)
}

pub fn money_text(value: i64, currency: &str) -> String {
    let negative = value < 0;
    let absolute = value.unsigned_abs();
    let whole = grouped_number(absolute / 100);
    let symbol = supported_currencies()
        .iter()
        .find(|item| item.code == currency)
        .map(|item| item.symbol.as_str())
        .unwrap_or(currency);
    let prefix = matches!(
        currency,
        "USD"
            | "CAD"
            | "AUD"
            | "NZD"
            | "GBP"
            | "EUR"
            | "JPY"
            | "CNY"
            | "INR"
            | "CHF"
            | "SEK"
            | "NOK"
            | "DKK"
            | "PLN"
            | "TRY"
            | "RUB"
            | "BRL"
            | "MXN"
            | "SGD"
            | "HKD"
    );
    let sign = if negative { "−" } else { "" };
    if prefix {
        format!("{sign}{symbol}{whole}.{:02}", absolute % 100)
    } else {
        format!("{sign}{whole}.{:02} {symbol}", absolute % 100)
    }
}

fn grouped_number(value: u64) -> String {
    let digits = value.to_string();
    let mut output = String::with_capacity(digits.len() + digits.len() / 3);
    for (index, character) in digits.chars().enumerate() {
        if index > 0 && (digits.len() - index).is_multiple_of(3) {
            output.push(',');
        }
        output.push(character);
    }
    output
}

fn default_currency() -> String {
    ["LC_ALL", "LC_MONETARY", "LANG"]
        .into_iter()
        .filter_map(|name| std::env::var(name).ok())
        .find(|value| !value.trim().is_empty())
        .as_deref()
        .and_then(currency_for_locale)
        .unwrap_or_else(|| "USD".to_string())
}

fn currency_for_locale(locale: &str) -> Option<String> {
    let normalized = locale.to_uppercase();
    let territory = normalized
        .split(['.', '@'])
        .next()
        .unwrap_or_default()
        .split(['_', '-'])
        .nth(1)
        .unwrap_or_default();
    territory
        .parse::<Country>()
        .ok()
        .and_then(|country| {
            Currency::from_country(country)
                .into_iter()
                .find(|currency| {
                    !currency.is_fund()
                        && !currency.is_special()
                        && currency.is_superseded().is_none()
                })
        })
        .map(|currency| currency.code().to_string())
        .filter(|code| supported_currencies().iter().any(|item| item.code == *code))
}

#[cfg(test)]
mod pure_unit_tests {
    use super::*;

    #[test]
    fn money_input_round_trips_cents_and_rejects_negative_values() {
        for (input, expected) in [("12", 1_200), ("12.3", 1_230), (",45", 45)] {
            assert_eq!(parse_money(input), Some(expected));
            assert_eq!(parse_money(&money_input_for_test(expected)), Some(expected));
        }
        assert_eq!(parse_money("-1"), None);
        assert_eq!(parse_money("1.234"), None);
    }

    #[test]
    fn money_display_handles_grouping_currency_position_and_i64_minimum() {
        assert_eq!(money_text(123_456_789, "USD"), "$1,234,567.89");
        assert_eq!(money_text(-123_456, "EUR"), "−€1,234.56");
        let minimum = money_text(i64::MIN, "USD");
        assert!(minimum.starts_with("−$"));
        assert!(minimum.ends_with(".08"));
        assert!(money_text(1_000, "XXX").ends_with(" XXX"));
    }

    #[test]
    fn date_parsing_and_ranges_reject_invalid_dates_and_use_transaction_extremes() {
        assert_eq!(
            parse_date(" 2024-02-29 "),
            NaiveDate::from_ymd_opt(2024, 2, 29)
        );
        assert_eq!(parse_date("2023-02-29"), None);
        assert_eq!(parse_date("2024/02/29"), None);

        let category = BWCategory {
            id: Uuid::new_v4(),
            ordinal: 0,
            title: "Test".to_string(),
            amount_planned: BWMoneyAmount { value: 0 },
            amount_actual: BWMoneyAmount { value: 0 },
            amount_accumulated: BWMoneyAmount { value: 0 },
            category_type: BWCategoryType::Expenses,
            transactions: ["2024-12-04", "2024-01-09", "not-a-date"]
                .into_iter()
                .map(|value| {
                    let (year, month, day) = parse_date(value)
                        .map(|date| (date.year(), date.month() as i32, date.day() as i32))
                        .unwrap_or((2024, 13, 1));
                    BWTransaction {
                        id: Uuid::new_v4(),
                        title: value.to_string(),
                        description: String::new(),
                        date: BWDate { year, month, day },
                        amount: BWMoneyAmount { value: 0 },
                    }
                })
                .collect(),
        };
        assert_eq!(
            category_date_range(&category),
            ("2024-01-09".to_string(), "2024-12-04".to_string())
        );
    }

    #[test]
    fn currency_catalog_is_sorted_and_excludes_invalid_currency_codes() {
        let currencies = supported_currencies();
        assert!(
            currencies
                .windows(2)
                .all(|pair| pair[0].name <= pair[1].name)
        );
        assert!(currencies.iter().any(|currency| currency.code == "USD"));
        assert!(!currencies.iter().any(|currency| currency.code == "XXX"));
    }

    #[test]
    fn locale_without_an_ordinary_currency_falls_back_without_panicking() {
        assert_eq!(currency_for_locale("en_AQ.UTF-8"), None);
        assert_eq!(currency_for_locale("en"), None);
        assert_eq!(currency_for_locale("en_US.UTF-8").as_deref(), Some("USD"));
    }

    fn money_input_for_test(value: i64) -> String {
        bw_core::money::format_money_input(BWMoneyAmount { value }).unwrap()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::{PermissionsExt, symlink};

    struct Fixture(PathBuf);

    impl Fixture {
        fn new() -> Self {
            let _ = initialize_core(Uuid::new_v4());
            let root = std::env::temp_dir().join(format!("bw-linux-tests-{}", Uuid::new_v4()));
            fs::create_dir_all(root.join("settings")).unwrap();
            Self(root)
        }

        fn state(&self) -> AppState {
            AppState {
                settings_dir: self.0.join("settings"),
                budget: None,
                recent_files: Vec::new(),
                currency: "USD".to_string(),
                page: AppPage::Budget,
                report_mode: ReportMode::Planned,
                saved_since_sync: false,
            }
        }

        fn budget(&self) -> BWBudget {
            budget_from_template(BWTemplateType::BasicMonthly, "Test".to_string())
        }
    }

    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn creating_budget_never_overwrites_existing_file() {
        let fixture = Fixture::new();
        let path = fixture.0.join("existing.budget");
        fs::write(&path, "existing data").unwrap();
        assert!(write_budget_exclusive(&fixture.budget(), &path).is_err());
        assert_eq!(fs::read_to_string(path).unwrap(), "existing data");
        assert_eq!(fs::read_dir(&fixture.0).unwrap().count(), 2);
    }

    #[test]
    fn saves_preserve_private_file_permissions() {
        let fixture = Fixture::new();
        let path = fixture.0.join("private.budget");
        let budget = fixture.budget();
        write_budget(&budget, &path).unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(0o600)).unwrap();
        write_budget(&budget, &path).unwrap();
        assert_eq!(
            fs::metadata(path).unwrap().permissions().mode() & 0o777,
            0o600
        );
    }

    #[test]
    fn editing_through_symlink_updates_target_and_keeps_link() {
        let fixture = Fixture::new();
        let target = fixture.0.join("target.budget");
        let link = fixture.0.join("link.budget");
        write_budget(&fixture.budget(), &target).unwrap();
        symlink(&target, &link).unwrap();
        let mut state = fixture.state();
        state.open_budget(&link).unwrap();
        state
            .create_category("Added through link", 123, BWCategoryType::Expenses)
            .unwrap();
        assert!(
            fs::symlink_metadata(&link)
                .unwrap()
                .file_type()
                .is_symlink()
        );
        assert!(
            read_budget(&target)
                .unwrap()
                .categories
                .iter()
                .any(|c| c.title == "Added through link")
        );
        assert_eq!(state.recent_files, vec![fs::canonicalize(target).unwrap()]);
    }

    #[test]
    fn recent_file_failure_does_not_turn_successful_create_or_edit_into_error() {
        let fixture = Fixture::new();
        let mut state = fixture.state();
        // A directory at the settings file path makes writing the recent list fail.
        fs::create_dir(state.settings_dir.join("recent-files")).unwrap();
        let path = fixture.0.join("created.budget");
        state
            .create_budget("Created", &BudgetTemplate::BasicMonthly, &path)
            .unwrap();
        assert!(!state.budget.as_ref().unwrap().categories.is_empty());
        let mut reopened = fixture.state();
        reopened.open_budget(&path).unwrap();
        assert!(reopened.budget.is_some());
        state
            .create_category("Saved", 100, BWCategoryType::Expenses)
            .unwrap();
        assert!(
            read_budget(&path)
                .unwrap()
                .categories
                .iter()
                .any(|c| c.title == "Saved")
        );
    }

    #[test]
    fn failed_currency_save_leaves_active_preference_unchanged() {
        let fixture = Fixture::new();
        let mut state = fixture.state();
        fs::create_dir(state.settings_dir.join("currency")).unwrap();
        assert!(state.set_currency("EUR".to_string()).is_err());
        assert_eq!(state.currency, "USD");
    }

    #[test]
    fn failed_mutation_preserves_memory_and_disk() {
        let fixture = Fixture::new();
        let mut state = fixture.state();
        let path = fixture.0.join("budget.budget");
        state
            .create_budget("Test", &BudgetTemplate::BasicMonthly, &path)
            .unwrap();
        let before = fs::read(&path).unwrap();
        let before_memory = encode_budget(state.budget.as_ref().unwrap()).unwrap();
        assert!(
            state
                .create_category("Invalid", -1, BWCategoryType::Expenses)
                .is_err()
        );
        assert_eq!(fs::read(&path).unwrap(), before);
        assert_eq!(
            encode_budget(state.budget.as_ref().unwrap()).unwrap(),
            before_memory
        );
    }

    #[test]
    fn saving_merges_changes_made_on_disk_since_open() {
        let fixture = Fixture::new();
        let mut state = fixture.state();
        let path = fixture.0.join("budget.budget");
        state
            .create_budget("Test", &BudgetTemplate::BasicMonthly, &path)
            .unwrap();
        let mut external = fixture.state();
        external.open_budget(&path).unwrap();
        external
            .create_category("External", 200, BWCategoryType::Income)
            .unwrap();
        state
            .create_category("Local", 100, BWCategoryType::Expenses)
            .unwrap();
        let saved = read_budget(&path).unwrap();
        assert!(saved.categories.iter().any(|c| c.title == "External"));
        assert!(saved.categories.iter().any(|c| c.title == "Local"));
    }
}
