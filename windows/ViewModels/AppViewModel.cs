using System.Collections.ObjectModel;
using System.Globalization;
using Bw_core;
using CommunityToolkit.Mvvm.ComponentModel;
using Windows.Globalization.NumberFormatting;
using CoreApi = Bw_core.Bw_core;

namespace BudgetWarden_Windows.ViewModels;

public sealed partial class AppViewModel : ObservableObject
{
    public ObservableCollection<CategoryRowViewModel> Categories { get; } = [];
    public ObservableCollection<CategoryGroupViewModel> CategoryGroups { get; } = [];
    public ObservableCollection<TransactionRowViewModel> Transactions { get; } = [];
    public ObservableCollection<ReportingRowViewModel> ReportingRows { get; } = [];
    public ObservableCollection<CategoryTypeOption> CategoryTypes { get; } =
    [
        new("Income", BwCategoryType.Income),
        new("Expenses", BwCategoryType.Expenses),
        new("Savings", BwCategoryType.Savings),
        new("Debt", BwCategoryType.Debt),
    ];

    public ObservableCollection<CurrencyOption> CurrencyOptions { get; } =
        new(CurrencyCatalog.All);

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(HasSelectedCategory))]
    public partial CategoryRowViewModel? SelectedCategory { get; set; }

    [ObservableProperty]
    public partial CategoryListItemViewModel? SelectedCategoryListItem { get; set; }

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(HasSelectedTransaction))]
    public partial TransactionRowViewModel? SelectedTransaction { get; set; }

    [ObservableProperty]
    public partial string SearchText { get; set; } = string.Empty;

    [ObservableProperty]
    public partial bool IsBudgetPage { get; private set; } = true;

    [ObservableProperty]
    public partial bool IsReportingPage { get; private set; }

    [ObservableProperty]
    public partial bool IsTransactionsPage { get; private set; }

    [ObservableProperty]
    public partial bool IsSettingsPage { get; private set; }

    [ObservableProperty]
    public partial bool IsStatusOpen { get; set; }

    [ObservableProperty]
    public partial string StatusMessage { get; private set; } = string.Empty;

    [ObservableProperty]
    public partial string IncomeTotal { get; private set; } = string.Empty;

    [ObservableProperty]
    public partial string PlannedAllocationTotal { get; private set; } = string.Empty;

    [ObservableProperty]
    public partial string ActualAllocationTotal { get; private set; } = string.Empty;

    [ObservableProperty]
    public partial string LeftToBudgetTotal { get; private set; } = string.Empty;

    [ObservableProperty]
    public partial ReportingPresentation Reporting { get; private set; } = ReportingPresentation.Empty;

    [ObservableProperty]
    public partial CurrencyOption SelectedCurrency { get; set; }

    public bool ShowWelcome => !HasBudget;
    public bool HasSelectedCategory => SelectedCategory is not null;
    public bool HasSelectedTransaction => SelectedTransaction is not null;
    public bool HasTransactions => Transactions.Count > 0;
    public bool IsRefreshing { get; private set; }
    public string BudgetTitle => CurrentBudget?.Title ?? "Budget Warden";

    public AppViewModel()
    {
        InitializePersistence();
        SelectedCurrency = CurrencyOptions.FirstOrDefault(item => item.Code == SelectedCurrencyCode)
            ?? CurrencyOptions[0];
    }

    partial void OnSearchTextChanged(string value) => RefreshTransactions();

    partial void OnSelectedCurrencyChanged(CurrencyOption value)
    {
        if (value is null || value.Code == SelectedCurrencyCode)
        {
            return;
        }

        SelectedCurrencyCode = value.Code;
        Refresh();
    }

    public void Navigate(string tag)
    {
        IsBudgetPage = tag == "budget";
        IsReportingPage = tag == "reporting";
        IsTransactionsPage = tag == "transactions";
        IsSettingsPage = tag == "settings";
    }

    public async Task<Exception?> RunAsync(Func<Task> action, string successMessage)
    {
        try
        {
            await action();
            StatusMessage = successMessage;
            IsStatusOpen = true;
            return null;
        }
        catch (Exception error) when (error is BoltException or IOException or UnauthorizedAccessException or ArgumentException or InvalidOperationException)
        {
            StatusMessage = error.Message;
            IsStatusOpen = true;
            return error;
        }
    }

    public async Task<IReadOnlyList<BudgetTemplate>> GetBudgetTemplatesAsync()
    {
        List<BudgetTemplate> templates =
        [
            new("Monthly Budget", BwTemplateType.BasicMonthly),
            new("Empty Budget", BwTemplateType.Empty),
        ];

        foreach (RecentBudget recent in RecentFiles.Take(5))
        {
            try
            {
                BwBudget previous = await ReadBudgetAsync(recent.Path);
                templates.Add(new($"Previous: {previous.Title}", BwTemplateType.Empty, previous));
            }
            catch (Exception error) when (error is BoltException or IOException or UnauthorizedAccessException)
            {
            }
        }

        return templates;
    }

    public void Refresh()
    {
        Guid? selectedCategoryId = SelectedCategory?.Id;
        Guid? selectedTransactionId = SelectedTransaction?.TransactionId;
        IsRefreshing = true;
        try
        {
            BwBudget? budget = CurrentBudget;
            ClearCollections();
            NotifyShellProperties();

            if (budget is not BwBudget current)
            {
                return;
            }

            foreach (BwCategory category in current.OrderedCategories(null))
            {
                Categories.Add(CategoryRowViewModel.From(category, FormatMoney));
            }

            AddCategoryGroup("Income", BwCategoryType.Income);
            AddCategoryGroup("Expenses", BwCategoryType.Expenses);
            AddCategoryGroup("Savings", BwCategoryType.Savings);
            AddCategoryGroup("Debt", BwCategoryType.Debt);

            RefreshTransactions();
            RefreshReporting(current);
            SelectedCategory = Categories.FirstOrDefault(item => item.Id == selectedCategoryId);
            SelectedCategoryListItem = CategoryGroups
                .SelectMany(group => group)
                .FirstOrDefault(item => item.Category?.Id == selectedCategoryId);
            SelectedTransaction = Transactions.FirstOrDefault(item => item.TransactionId == selectedTransactionId);
        }
        finally
        {
            IsRefreshing = false;
        }
    }

    private void RefreshTransactions()
    {
        Transactions.Clear();
        if (CurrentBudget is not BwBudget budget)
        {
            OnPropertyChanged(nameof(HasTransactions));
            return;
        }

        IEnumerable<TransactionRowViewModel> rows = budget.Categories
            .SelectMany(category => category.Transactions.Select(transaction =>
                TransactionRowViewModel.From(category, transaction, FormatMoney)))
            .OrderByDescending(row => row.SortDate)
            .ThenBy(row => row.Title);

        if (!string.IsNullOrWhiteSpace(SearchText))
        {
            rows = rows.Where(row =>
                row.Title.Contains(SearchText, StringComparison.CurrentCultureIgnoreCase)
                || row.Category.Contains(SearchText, StringComparison.CurrentCultureIgnoreCase)
                || row.Description.Contains(SearchText, StringComparison.CurrentCultureIgnoreCase));
        }

        foreach (TransactionRowViewModel row in rows)
        {
            Transactions.Add(row);
        }
        OnPropertyChanged(nameof(HasTransactions));
    }

    private void AddCategoryGroup(string title, BwCategoryType type)
    {
        CategoryRowViewModel[] rows = Categories
            .Where(category => category.Category.CategoryType == type)
            .ToArray();
        CategoryGroups.Add(new(title, type, rows));
    }

    private void RefreshReporting(BwBudget budget)
    {
        BwReportingSummary report = CoreApi.BuildReportingSummary(budget);
        IncomeTotal = FormatMoney(report.Totals.Income.Value);
        PlannedAllocationTotal = FormatMoney(report.Totals.PlannedAllocation.Value);
        ActualAllocationTotal = FormatMoney(report.Totals.ActualAllocation.Value);
        LeftToBudgetTotal = FormatMoney(report.Totals.LeftToBudget);
        Reporting = ReportingPresentation.From(report, FormatMoney);

        foreach (BwReportingCategorySegment segment in report.CategorySegments
                     .Where(item => item.AmountMode == BwReportingAmountMode.Actual)
                     .OrderBy(item => item.CategoryType)
                     .ThenBy(item => item.Title))
        {
            BwCategory category = budget.Categories.First(item => item.Id == segment.CategoryId);
            ReportingRows.Add(new(
                TypeLabel(segment.CategoryType),
                segment.Title,
                FormatMoney(category.AmountPlanned.Value),
                FormatMoney(segment.Amount.Value),
                Progress(category.AmountPlanned.Value, segment.Amount.Value)));
        }
    }

    private double Progress(long planned, long actual) =>
        planned <= 0 ? 0 : Math.Clamp((double)actual / planned * 100, 0, 100);

    private string FormatMoney(long cents)
    {
        CurrencyFormatter formatter = new(SelectedCurrency.Code)
        {
            IsGrouped = true,
        };
        return formatter.FormatDouble((double)cents / 100.0);
    }

    private static string TypeLabel(BwCategoryType type) => type switch
    {
        BwCategoryType.Income => "Income",
        BwCategoryType.Expenses => "Expenses",
        BwCategoryType.Savings => "Savings",
        BwCategoryType.Debt => "Debt",
        _ => type.ToString(),
    };

    private void ClearCollections()
    {
        Categories.Clear();
        CategoryGroups.Clear();
        Transactions.Clear();
        OnPropertyChanged(nameof(HasTransactions));
        ReportingRows.Clear();
        Reporting = ReportingPresentation.Empty;
    }

    private void NotifyShellProperties()
    {
        OnPropertyChanged(nameof(ShowWelcome));
        OnPropertyChanged(nameof(HasBudget));
        OnPropertyChanged(nameof(BudgetTitle));
    }
}

public sealed record CurrencyOption(string Code, string Name, string Symbol)
{
    public string DisplayName => $"{Code} — {Name}";
}

public sealed record CategoryTypeOption(string DisplayName, BwCategoryType Value)
{
    public bool HasAccumulated => Value is BwCategoryType.Savings or BwCategoryType.Debt;
}

public sealed partial class CategoryGroupViewModel(
    string title,
    BwCategoryType categoryType,
    IEnumerable<CategoryRowViewModel> categories)
    : ObservableCollection<CategoryListItemViewModel>(
        categories
            .Select(CategoryListItemViewModel.ForCategory)
            .Append(CategoryListItemViewModel.Footer(categoryType)))
{
    public string Title { get; } = title;
    public bool HasAccumulated => categoryType is BwCategoryType.Savings or BwCategoryType.Debt;
    public string AccumulatedLabel => categoryType == BwCategoryType.Debt ? "Leftover debt" : "Accumulated";
}

public sealed record CategoryListItemViewModel(
    CategoryRowViewModel? Category,
    BwCategoryType CategoryType,
    bool IsFooter,
    string ActionLabel)
{
    public bool IsCategory => !IsFooter;
    public string Title => Category?.Title ?? string.Empty;
    public string Planned => Category?.Planned ?? string.Empty;
    public string Actual => Category?.Actual ?? string.Empty;
    public string Accumulated => Category?.Accumulated ?? string.Empty;
    public bool HasAccumulated => CategoryType is BwCategoryType.Savings or BwCategoryType.Debt;
    public string AutomationId => $"Create{CategoryType}CategoryFooterButton";

    public static CategoryListItemViewModel ForCategory(CategoryRowViewModel category) =>
        new(category, category.Category.CategoryType, false, string.Empty);

    public static CategoryListItemViewModel Footer(BwCategoryType categoryType) =>
        new(null, categoryType, true, categoryType switch
        {
            BwCategoryType.Income => "New Income",
            BwCategoryType.Expenses => "New Category",
            BwCategoryType.Savings => "New Fund",
            BwCategoryType.Debt => "New Debt",
            _ => "New Category",
        });
}

public sealed record CategoryRowViewModel(
    Guid Id,
    BwCategory Category,
    string Type,
    string Title,
    string Planned,
    string Actual,
    string Accumulated)
{
    public override string ToString() => Title;

    public static CategoryRowViewModel From(BwCategory category, Func<long, string> format) => new(
        category.Id,
        category,
        AppViewModelTypeLabel(category.CategoryType),
        category.Title,
        format(category.AmountPlanned.Value),
        format(category.AmountActual.Value),
        format(category.AmountAccumulated.Value));

    private static string AppViewModelTypeLabel(BwCategoryType type) => type switch
    {
        BwCategoryType.Income => "Income",
        BwCategoryType.Expenses => "Expenses",
        BwCategoryType.Savings => "Savings",
        BwCategoryType.Debt => "Debt",
        _ => type.ToString(),
    };
}

public sealed record TransactionRowViewModel(
    Guid CategoryId,
    Guid TransactionId,
    BwTransaction Transaction,
    string Category,
    string Title,
    string Description,
    string Date,
    string Amount,
    DateTime SortDate)
{
    public override string ToString() => Title;

    public static TransactionRowViewModel From(
        BwCategory category,
        BwTransaction transaction,
        Func<long, string> format)
    {
        DateTime date = new(transaction.Date.Year, transaction.Date.Month, transaction.Date.Day);
        return new(
            category.Id,
            transaction.Id,
            transaction,
            category.Title,
            transaction.Title,
            transaction.Description,
            date.ToString("d", CultureInfo.CurrentCulture),
            format(transaction.Amount.Value),
            date);
    }
}

public sealed record ReportingRowViewModel(
    string Type,
    string Title,
    string Planned,
    string Actual,
    double Progress)
{
    public override string ToString() => Title;
}
