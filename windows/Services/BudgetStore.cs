using System.Collections.ObjectModel;
using System.Text.Json;
using Bw_core;
using CommunityToolkit.Mvvm.ComponentModel;
using Windows.Storage;
using CoreApi = Bw_core.Bw_core;

namespace BudgetWarden_Windows.Services;

public sealed partial class BudgetStore : ObservableObject
{
    private const string DeviceIdKey = "BW_DEVICE_ID";
    private const string CurrencyKey = "BW_CURRENCY";
    private const string RecentFilesKey = "BW_RECENT_FILES_V1";

    private readonly ApplicationDataContainer _settings = ApplicationData.Current.LocalSettings;

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(HasBudget))]
    public partial BwBudget? CurrentBudget { get; private set; }

    [ObservableProperty]
    public partial string SelectedCurrencyCode { get; set; }

    public bool HasBudget => CurrentBudget is not null;

    public ObservableCollection<RecentBudget> RecentFiles { get; } = [];

    public BudgetStore()
    {
        SelectedCurrencyCode = ReadSetting(CurrencyKey) ?? "USD";
        InitializeCore();
        LoadRecentFiles();
    }

    partial void OnSelectedCurrencyCodeChanged(string value) =>
        _settings.Values[CurrencyKey] = value;

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

    public async Task CreateCategoryAsync(string title, string plannedAmount, BwCategoryType categoryType)
    {
        BwBudget budget = RequireBudget();
        BwMoneyAmount amount = CoreApi.ParseMoneyAmount(plannedAmount, 0)
            ?? throw new ArgumentException("Enter a valid planned amount.", nameof(plannedAmount));
        string trimmedTitle = title.Trim();
        if (trimmedTitle.Length == 0)
        {
            throw new ArgumentException("A category title is required.", nameof(title));
        }

        int ordinal = budget.Categories.Count(item => item.CategoryType == categoryType);
        BwCategory category = new(
            Guid.NewGuid(),
            ordinal,
            trimmedTitle,
            amount,
            new BwMoneyAmount(0),
            new BwMoneyAmount(0),
            categoryType,
            []);

        await MutateAsync(current => CoreApi.CreateCategory(current, category));
    }

    public async Task UpdateCategoryAsync(Guid categoryId, string title, string plannedAmount, BwCategoryType categoryType)
    {
        BwBudget budget = RequireBudget();
        BwCategory existing = budget.Categories.First(item => item.Id == categoryId);
        BwMoneyAmount amount = CoreApi.ParseMoneyAmount(plannedAmount, 0)
            ?? throw new ArgumentException("Enter a valid planned amount.", nameof(plannedAmount));
        string trimmedTitle = title.Trim();
        if (trimmedTitle.Length == 0)
        {
            throw new ArgumentException("A category title is required.", nameof(title));
        }

        BwCategory updated = existing with
        {
            Title = trimmedTitle,
            AmountPlanned = amount,
            CategoryType = categoryType,
        };
        await MutateAsync(current => CoreApi.UpdateCategory(current, updated));
    }

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

    public void CloseBudget() => CurrentBudget = null;

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

        foreach (string path in JsonSerializer.Deserialize<string[]>(serialized) ?? [])
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

        _settings.Values[RecentFilesKey] = JsonSerializer.Serialize(RecentFiles.Select(item => item.Path));
    }

    private string? ReadSetting(string key) => _settings.Values[key] as string;
}

public sealed record RecentBudget(string Title, string Folder, string Path)
{
    public static RecentBudget FromPath(string path) => new(
        System.IO.Path.GetFileNameWithoutExtension(path),
        System.IO.Path.GetDirectoryName(path) ?? string.Empty,
        path);
}

public sealed record BudgetTemplate(string DisplayName, BwTemplateType TemplateType, BwBudget? PreviousBudget = null);
