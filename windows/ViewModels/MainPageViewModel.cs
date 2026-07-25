using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Globalization;
using Bw_core;
using CommunityToolkit.Mvvm.ComponentModel;
using BudgetWarden_Windows.Services;
using CoreApi = Bw_core.Bw_core;

namespace BudgetWarden_Windows.ViewModels;

public sealed partial class MainPageViewModel : ObservableObject
{
    public BudgetStore Store { get; } = new();

    public ObservableCollection<CategoryRowViewModel> Categories { get; } = [];
    public ObservableCollection<TransactionRowViewModel> Transactions { get; } = [];
    public ObservableCollection<ReportingRowViewModel> ReportingRows { get; } = [];
    public ObservableCollection<CurrencyOption> CurrencyOptions { get; } =
    [
        new("USD", "USD — US Dollar", "$"),
        new("EUR", "EUR — Euro", "€"),
        new("GBP", "GBP — British Pound", "£"),
        new("BGN", "BGN — Bulgarian Lev", "лв."),
        new("CAD", "CAD — Canadian Dollar", "CA$"),
        new("AUD", "AUD — Australian Dollar", "A$"),
        new("JPY", "JPY — Japanese Yen", "¥"),
    ];

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(HasSelectedCategory))]
    public partial CategoryRowViewModel? SelectedCategory { get; set; }

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
    public partial CurrencyOption SelectedCurrency { get; set; }

    public bool ShowWelcome => !Store.HasBudget;
    public bool HasBudget => Store.HasBudget;
    public bool HasSelectedCategory => SelectedCategory is not null;
    public bool HasSelectedTransaction => SelectedTransaction is not null;
    public string BudgetTitle => Store.CurrentBudget?.Title ?? "Budget Warden";
    public ObservableCollection<RecentBudget> RecentFiles => Store.RecentFiles;

    public MainPageViewModel()
    {
        SelectedCurrency = CurrencyOptions.FirstOrDefault(item => item.Code == Store.SelectedCurrencyCode)
            ?? CurrencyOptions[0];
        Store.PropertyChanged += Store_PropertyChanged;
    }

    partial void OnSearchTextChanged(string value) => RefreshTransactions();

    partial void OnSelectedCurrencyChanged(CurrencyOption value)
    {
        if (value is null)
        {
            return;
        }

        Store.SelectedCurrencyCode = value.Code;
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
            Refresh();
            return null;
        }
        catch (Exception error) when (error is BoltException or IOException or UnauthorizedAccessException or ArgumentException or InvalidOperationException)
        {
            StatusMessage = error.Message;
            IsStatusOpen = true;
            return error;
        }
    }

    public void CloseBudget()
    {
        Store.CloseBudget();
        SelectedCategory = null;
        SelectedTransaction = null;
        Refresh();
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
                BwBudget previous = await Store.ReadBudgetAsync(recent.Path);
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
        BwBudget? budget = Store.CurrentBudget;
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

        RefreshTransactions();
        RefreshReporting(current);
    }

    private void RefreshTransactions()
    {
        Transactions.Clear();
        if (Store.CurrentBudget is not BwBudget budget)
        {
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
    }

    private void RefreshReporting(BwBudget budget)
    {
        BwReportingSummary report = CoreApi.BuildReportingSummary(budget);
        IncomeTotal = FormatMoney(report.Totals.Income.Value);
        PlannedAllocationTotal = FormatMoney(report.Totals.PlannedAllocation.Value);
        ActualAllocationTotal = FormatMoney(report.Totals.ActualAllocation.Value);
        LeftToBudgetTotal = FormatMoney(report.Totals.LeftToBudget);

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
        decimal amount = cents / 100m;
        return string.Format(CultureInfo.CurrentCulture, "{0} {1:N2}", SelectedCurrency.Symbol, amount);
    }

    private static string TypeLabel(BwCategoryType type) => type switch
    {
        BwCategoryType.Income => "Income",
        BwCategoryType.Expenses => "Expenses",
        BwCategoryType.Savings => "Savings",
        BwCategoryType.Debt => "Debt",
        _ => type.ToString(),
    };

    private void Store_PropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(BudgetStore.CurrentBudget))
        {
            Refresh();
        }
    }

    private void ClearCollections()
    {
        Categories.Clear();
        Transactions.Clear();
        ReportingRows.Clear();
    }

    private void NotifyShellProperties()
    {
        OnPropertyChanged(nameof(ShowWelcome));
        OnPropertyChanged(nameof(HasBudget));
        OnPropertyChanged(nameof(BudgetTitle));
    }
}

public sealed record CurrencyOption(string Code, string DisplayName, string Symbol);

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
        MainPageViewModelTypeLabel(category.CategoryType),
        category.Title,
        format(category.AmountPlanned.Value),
        format(category.AmountActual.Value),
        format(category.AmountAccumulated.Value));

    private static string MainPageViewModelTypeLabel(BwCategoryType type) => type switch
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
