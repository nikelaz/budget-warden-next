using System.Collections.ObjectModel;
using System.Text.Json;
using Bw_core;
using CommunityToolkit.Mvvm.ComponentModel;
using Windows.Storage;
using CoreApi = Bw_core.Bw_core;

namespace BudgetWarden_Windows.ViewModels;

public sealed partial class AppViewModel
{
    private const string DeviceIdKey = "BW_DEVICE_ID";
    private const string CurrencyKey = "BW_CURRENCY";
    private const string RecentFilesKey = "BW_RECENT_FILES_V1";

    private readonly ApplicationDataContainer _settings = ApplicationData.Current.LocalSettings;

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(HasBudget))]
    [NotifyPropertyChangedFor(nameof(ShowWelcome))]
    [NotifyPropertyChangedFor(nameof(BudgetTitle))]
    public partial BwBudget? CurrentBudget { get; private set; }

    [ObservableProperty]
    public partial string SelectedCurrencyCode { get; set; }

    public bool HasBudget => CurrentBudget is not null;

    public ObservableCollection<RecentBudget> RecentFiles { get; } = [];

    private void InitializePersistence()
    {
        SelectedCurrencyCode = ReadSetting(CurrencyKey) ?? "USD";
        InitializeCore();
        LoadRecentFiles();
    }

    partial void OnSelectedCurrencyCodeChanged(string value) =>
        _settings.Values[CurrencyKey] = value;

    partial void OnCurrentBudgetChanged(BwBudget? value)
    {
        UpdateRecentBudgetSelection();
        Refresh();
    }

    public async Task<BwBudget> ReadBudgetAsync(string path)
    {
        string normalizedPath = ValidateBudgetPath(path);
        string json = await File.ReadAllTextAsync(normalizedPath).ConfigureAwait(false);
        BwBudget budget = CoreApi.DecodeBudget(json, normalizedPath);

        if (budget.RequiresMigrationWriteback)
        {
            await WriteBudgetAsync(budget, normalizedPath).ConfigureAwait(false);
            budget = budget with { RequiresMigrationWriteback = false };
        }

        return budget;
    }

    public async Task OpenBudgetAsync(string path)
    {
        BwBudget budget = await ReadBudgetAsync(path);
        CurrentBudget = budget;
        RememberRecent(path);
    }

    public async Task CreateBudgetAsync(string title, BudgetTemplate template, string path)
    {
        string trimmedTitle = title.Trim();
        if (trimmedTitle.Length == 0)
        {
            throw new ArgumentException("A budget title is required.", nameof(title));
        }

        BwBudget budget = template.PreviousBudget is BwBudget previous
            ? CoreApi.BudgetFromPreviousBudget(previous, trimmedTitle)
            : CoreApi.BudgetFromTemplate(template.TemplateType, trimmedTitle);

        string normalizedPath = ValidateBudgetPath(path);
        budget = budget with { Url = normalizedPath };
        await WriteBudgetAsync(budget, normalizedPath);
        CurrentBudget = budget;
        RememberRecent(normalizedPath);
    }

    public async Task CreateCategoryAsync(
        string title,
        string plannedAmount,
        string accumulatedAmount,
        BwCategoryType categoryType)
    {
        BwBudget budget = RequireBudget();
        BwMoneyAmount amount = CoreApi.ParseMoneyAmount(plannedAmount, 0)
            ?? throw new ArgumentException("Enter a valid planned amount.", nameof(plannedAmount));
        BwMoneyAmount accumulated = HasAccumulatedAmount(categoryType)
            ? CoreApi.ParseMoneyAmount(accumulatedAmount, 0)
                ?? throw new ArgumentException("Enter a valid accumulated amount.", nameof(accumulatedAmount))
            : new BwMoneyAmount(0);
        string trimmedTitle = title.Trim();
        if (trimmedTitle.Length == 0)
        {
            throw new ArgumentException("A category title is required.", nameof(title));
        }

        int ordinal = budget.Categories.Count(item => item.CategoryType == categoryType);
        BwCategory category = new(
            Id: Guid.NewGuid(),
            Ordinal: ordinal,
            Title: trimmedTitle,
            AmountPlanned: amount,
            AmountActual: new BwMoneyAmount(0),
            AmountAccumulated: accumulated,
            CategoryType: categoryType,
            Transactions: []);

        await MutateAsync(current => CoreApi.CreateCategory(current, category));
    }

    public async Task UpdateCategoryAsync(
        Guid categoryId,
        string title,
        string plannedAmount,
        string accumulatedAmount,
        BwCategoryType categoryType)
    {
        BwBudget budget = RequireBudget();
        BwCategory existing = budget.Categories.First(item => item.Id == categoryId);
        BwMoneyAmount amount = CoreApi.ParseMoneyAmount(plannedAmount, 0)
            ?? throw new ArgumentException("Enter a valid planned amount.", nameof(plannedAmount));
        BwMoneyAmount accumulated = HasAccumulatedAmount(categoryType)
            ? CoreApi.ParseMoneyAmount(accumulatedAmount, 0)
                ?? throw new ArgumentException("Enter a valid accumulated amount.", nameof(accumulatedAmount))
            : new BwMoneyAmount(0);
        string trimmedTitle = title.Trim();
        if (trimmedTitle.Length == 0)
        {
            throw new ArgumentException("A category title is required.", nameof(title));
        }

        BwCategory updated = existing with
        {
            Title = trimmedTitle,
            AmountPlanned = amount,
            AmountAccumulated = accumulated,
            CategoryType = categoryType,
        };
        if (updated == existing)
        {
            return;
        }

        await MutateAsync(current => CoreApi.UpdateCategory(current, updated));
    }

    private static bool HasAccumulatedAmount(BwCategoryType categoryType) =>
        categoryType is BwCategoryType.Savings or BwCategoryType.Debt;

    public Task DeleteCategoryAsync(Guid categoryId) =>
        MutateAsync(current => CoreApi.DeleteCategory(current, categoryId));

    public async Task CreateTransactionAsync(
        Guid categoryId,
        string title,
        string description,
        DateTimeOffset date,
        string amountText)
    {
        BwMoneyAmount amount = CoreApi.ParseMoneyAmount(amountText, null)
            ?? throw new ArgumentException("Enter a valid transaction amount.", nameof(amountText));
        if (amount.Value <= 0)
        {
            throw new ArgumentOutOfRangeException(nameof(amountText), "The transaction amount must be greater than zero.");
        }

        string trimmedTitle = title.Trim();
        if (trimmedTitle.Length == 0)
        {
            throw new ArgumentException("A transaction title is required.", nameof(title));
        }

        BwDate coreDate = new(date.Year, date.Month, date.Day);
        BwTransaction transaction = CoreApi.NewTransaction(trimmedTitle, description.Trim(), coreDate, amount);
        await MutateAsync(current => CoreApi.CreateTransaction(current, categoryId, transaction));
    }

    public Task DeleteTransactionAsync(Guid categoryId, Guid transactionId) =>
        MutateAsync(current => CoreApi.DeleteTransaction(current, categoryId, transactionId));

    public async Task UpdateTransactionAsync(
        Guid categoryId,
        Guid targetCategoryId,
        Guid transactionId,
        string title,
        string description,
        DateTimeOffset date,
        string amountText)
    {
        BwBudget budget = RequireBudget();
        BwCategory category = budget.Categories.First(item => item.Id == categoryId);
        BwTransaction existing = category.Transactions.First(item => item.Id == transactionId);
        BwMoneyAmount amount = CoreApi.ParseMoneyAmount(amountText, null)
            ?? throw new ArgumentException("Enter a valid transaction amount.", nameof(amountText));
        if (amount.Value <= 0)
        {
            throw new ArgumentOutOfRangeException(nameof(amountText), "The transaction amount must be greater than zero.");
        }

        string trimmedTitle = title.Trim();
        if (trimmedTitle.Length == 0)
        {
            throw new ArgumentException("A transaction title is required.", nameof(title));
        }

        BwTransaction updated = existing with
        {
            Title = trimmedTitle,
            Description = description.Trim(),
            Date = new BwDate(date.Year, date.Month, date.Day),
            Amount = amount,
        };
        if (updated == existing && categoryId == targetCategoryId)
        {
            return;
        }

        await MutateAsync(current =>
        {
            BwBudget result = CoreApi.UpdateTransaction(current, categoryId, updated);
            return categoryId == targetCategoryId
                ? result
                : CoreApi.MoveTransaction(result, categoryId, targetCategoryId, transactionId);
        });
    }

    private async Task MutateAsync(Func<BwBudget, BwBudget> mutation)
    {
        BwBudget current = RequireBudget();
        BwBudget updated = mutation(current).UpdateActuals();
        string path = ValidateBudgetPath(updated.Url ?? current.Url ?? string.Empty);
        updated = updated with { Url = path };
        await WriteBudgetAsync(updated, path);
        CurrentBudget = updated;
        RememberRecent(path);
    }

    private static async Task WriteBudgetAsync(BwBudget budget, string path)
    {
        CoreApi.ValidateBudget(budget);
        string json = CoreApi.EncodeBudget(budget);
        string directory = Path.GetDirectoryName(path)
            ?? throw new IOException("The selected budget path has no parent folder.");
        Directory.CreateDirectory(directory);
        string temporaryPath = Path.Combine(directory, $".{Path.GetFileName(path)}.{Guid.NewGuid():N}.tmp");

        try
        {
            await File.WriteAllTextAsync(temporaryPath, json).ConfigureAwait(false);
            File.Move(temporaryPath, path, true);
        }
        finally
        {
            if (File.Exists(temporaryPath))
            {
                File.Delete(temporaryPath);
            }
        }
    }

    private BwBudget RequireBudget() =>
        CurrentBudget ?? throw new InvalidOperationException("Open or create a budget first.");

    private static string ValidateBudgetPath(string path)
    {
        if (string.IsNullOrWhiteSpace(path))
        {
            throw new IOException("No budget file was selected.");
        }

        string normalizedPath = Path.GetFullPath(path);
        if (!string.Equals(Path.GetExtension(normalizedPath), ".budget", StringComparison.OrdinalIgnoreCase))
        {
            throw new IOException("Budget Warden files must use the .budget extension.");
        }

        return normalizedPath;
    }

    private void InitializeCore()
    {
        Guid deviceId;
        if (!Guid.TryParse(ReadSetting(DeviceIdKey), out deviceId))
        {
            deviceId = Guid.NewGuid();
            _settings.Values[DeviceIdKey] = deviceId.ToString("D");
        }

        try
        {
            CoreApi.InitializeCore(deviceId);
        }
        catch (BoltException error) when (error.Message.Contains("already initialized", StringComparison.OrdinalIgnoreCase))
        {
        }
    }

    private void LoadRecentFiles()
    {
        string? serialized = ReadSetting(RecentFilesKey);
        if (serialized is null)
        {
            return;
        }

        foreach (string path in JsonSerializer.Deserialize(
                     serialized,
                     AppJsonContext.Default.StringArray) ?? [])
        {
            if (File.Exists(path) && string.Equals(Path.GetExtension(path), ".budget", StringComparison.OrdinalIgnoreCase))
            {
                RecentFiles.Add(RecentBudget.FromPath(path));
            }
        }
    }

    private void RememberRecent(string path)
    {
        string normalizedPath = Path.GetFullPath(path);
        RecentBudget? duplicate = RecentFiles.FirstOrDefault(item =>
            string.Equals(item.Path, normalizedPath, StringComparison.OrdinalIgnoreCase));
        if (duplicate is not null)
        {
            RecentFiles.Remove(duplicate);
        }

        RecentFiles.Insert(0, RecentBudget.FromPath(normalizedPath));
        while (RecentFiles.Count > 10)
        {
            RecentFiles.RemoveAt(RecentFiles.Count - 1);
        }

        UpdateRecentBudgetSelection();
        string[] recentPaths = RecentFiles.Select(item => item.Path).ToArray();
        _settings.Values[RecentFilesKey] = JsonSerializer.Serialize(
            recentPaths,
            AppJsonContext.Default.StringArray);
    }

    private void UpdateRecentBudgetSelection()
    {
        string? currentPath = CurrentBudget?.Url;
        foreach (RecentBudget recent in RecentFiles)
        {
            recent.IsCurrent = currentPath is not null
                && string.Equals(recent.Path, currentPath, StringComparison.OrdinalIgnoreCase);
        }
    }

    private string? ReadSetting(string key) => _settings.Values[key] as string;
}

public sealed partial class RecentBudget(string title, string folder, string path) : ObservableObject
{
    public string Title { get; } = title;
    public string Folder { get; } = folder;
    public string Path { get; } = path;

    [ObservableProperty]
    public partial bool IsCurrent { get; set; }

    public static RecentBudget FromPath(string path) => new(
        System.IO.Path.GetFileNameWithoutExtension(path),
        System.IO.Path.GetDirectoryName(path) ?? string.Empty,
        path);
}

public sealed record BudgetTemplate(string DisplayName, BwTemplateType TemplateType, BwBudget? PreviousBudget = null);
