using Bw_core;
using CommunityToolkit.Mvvm.ComponentModel;
using CoreApi = Bw_core.Bw_core;

namespace BudgetWarden_Windows.ViewModels;

public sealed partial class AppViewModel
{
    private const string McpEnabledKey = "BW_MCP_ENABLED";
    private const string McpAllowNetworkKey = "BW_MCP_ALLOW_NETWORK";
    private const string McpPortKey = "BW_MCP_PORT";
    private const string McpTokenKey = "BW_MCP_TOKEN";

    private readonly BwMcpServer _mcpServer = new();
    private McpBudgetHost? _mcpHost;

    [ObservableProperty]
    public partial bool IsMcpServerEnabled { get; private set; }

    [ObservableProperty]
    public partial bool McpServerAllowsNetwork { get; private set; }

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(HasMcpServerUrl))]
    public partial string? McpServerUrl { get; private set; }

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(HasMcpServerError))]
    public partial string? McpServerError { get; private set; }

    public bool HasMcpServerUrl => McpServerUrl is not null;
    public bool HasMcpServerError => McpServerError is not null;

    private void InitializeMcpServer()
    {
        if ((ReadSetting(McpTokenKey) ?? string.Empty).Length < 16)
        {
            _settings.Values[McpTokenKey] = CoreApi.GenerateMcpToken();
        }

        _mcpHost = new McpBudgetHost(
            Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments),
                "Budget Warden"),
            OnMcpEvent);
        ShareBudgetsWithMcp();
        ApplyMcpSettings();
    }

    public void SetMcpServerEnabled(bool isEnabled)
    {
        _settings.Values[McpEnabledKey] = isEnabled;
        ApplyMcpSettings();
    }

    public void SetMcpServerAllowsNetwork(bool allowsNetwork)
    {
        _settings.Values[McpAllowNetworkKey] = allowsNetwork;
        ApplyMcpSettings();
    }

    /// <summary>Replaces the secret in the server URL, disconnecting existing clients.</summary>
    public void RegenerateMcpServerUrl()
    {
        _settings.Values[McpTokenKey] = CoreApi.GenerateMcpToken();
        ApplyMcpSettings();
    }

    private void ApplyMcpSettings()
    {
        IsMcpServerEnabled = _settings.Values[McpEnabledKey] is true;
        McpServerAllowsNetwork = _settings.Values[McpAllowNetworkKey] is true;
        McpServerError = null;

        if (!IsMcpServerEnabled || _mcpHost is null)
        {
            _mcpServer.Stop();
            McpServerUrl = null;
            return;
        }

        try
        {
            BwMcpServerStatus status = _mcpServer.Start(
                _mcpHost,
                new BwMcpServerConfig(
                    _settings.Values[McpPortKey] is int port ? port : 0,
                    ReadSetting(McpTokenKey) ?? string.Empty,
                    McpServerAllowsNetwork));
            McpServerUrl = status.Url;
        }
        catch (BoltException error)
        {
            McpServerUrl = null;
            McpServerError = error.Message;
        }
    }

    private void ShareBudgetsWithMcp() =>
        _mcpHost?.Update(
            CurrentBudget?.Url,
            RecentFiles.Select(item => item.Path).ToArray(),
            SelectedCurrencyCode);

    private void OnMcpEvent(McpBudgetEvent budgetEvent, string path)
    {
        App.DispatcherQueue?.TryEnqueue(async () =>
        {
            try
            {
                switch (budgetEvent)
                {
                    case McpBudgetEvent.Changed when IsCurrentBudgetPath(path):
                        BwBudget reloaded = await ReadBudgetAsync(path);
                        // The user may have switched or closed budgets during the read.
                        if (IsCurrentBudgetPath(path))
                        {
                            CurrentBudget = reloaded;
                        }

                        break;
                    case McpBudgetEvent.Created:
                        RememberRecent(path);
                        break;
                    case McpBudgetEvent.Show:
                        await OpenBudgetAsync(path);
                        break;
                }
            }
            catch (Exception error) when (error is BoltException or IOException or UnauthorizedAccessException)
            {
                StatusMessage = error.Message;
                IsStatusOpen = true;
            }
        });
    }

    private bool IsCurrentBudgetPath(string path) =>
        string.Equals(CurrentBudget?.Url, path, StringComparison.OrdinalIgnoreCase);
}

internal enum McpBudgetEvent
{
    Changed,
    Created,
    Show,
}

/// <summary>
/// File access for the core MCP server. It is called from server threads and
/// only reaches the open budget, recent budgets, and budgets it created.
/// </summary>
internal sealed class McpBudgetHost(string newBudgetDirectory, Action<McpBudgetEvent, string> notify) : BwMcpHost
{
    private readonly Lock _lock = new();
    private string? _openPath;
    private string[] _recentPaths = [];
    private readonly List<string> _createdPaths = [];
    private string _currency = "USD";

    public void Update(string? openPath, string[] recentPaths, string currency)
    {
        lock (_lock)
        {
            _openPath = openPath;
            _recentPaths = recentPaths;
            _currency = currency;
            _createdPaths.RemoveAll(path => recentPaths.Contains(path, StringComparer.OrdinalIgnoreCase));
        }
    }

    public BwMcpBudgetLocation[] ListBudgets()
    {
        lock (_lock)
        {
            return KnownPaths()
                .Select(path => new BwMcpBudgetLocation(
                    path,
                    string.Equals(path, _openPath, StringComparison.OrdinalIgnoreCase)))
                .ToArray();
        }
    }

    public string ReadBudgetFile(string location) => File.ReadAllText(KnownPath(location));

    public bool WriteBudgetFile(string location, string json, string? expectedRevisionId)
    {
        string path = KnownPath(location);
        CoreApi.DecodeBudget(json, path);
        AppViewModel.BudgetSaveGate.Wait();
        try
        {
            // Another writer saved since the server read the budget.
            if (expectedRevisionId is not null
                && CoreApi.DecodeBudget(File.ReadAllText(path), path).RevisionId != Guid.Parse(expectedRevisionId))
            {
                return false;
            }

            WriteAtomically(path, json, overwrite: true);
            return true;
        }
        finally
        {
            AppViewModel.BudgetSaveGate.Release();
        }
    }

    public string CreateBudgetFile(string fileName, string json)
    {
        CoreApi.DecodeBudget(json, string.Empty);
        Directory.CreateDirectory(newBudgetDirectory);
        string stem = Path.GetFileNameWithoutExtension(fileName);
        string path = Path.Combine(newBudgetDirectory, fileName);
        for (int index = 2; File.Exists(path); index++)
        {
            path = Path.Combine(newBudgetDirectory, $"{stem} {index}.budget");
        }

        WriteAtomically(path, json, overwrite: false);
        lock (_lock)
        {
            _createdPaths.Add(path);
        }

        notify(McpBudgetEvent.Created, path);
        return path;
    }

    public void BudgetDidChange(string location) => notify(McpBudgetEvent.Changed, location);

    public void ShowBudget(string location) => notify(McpBudgetEvent.Show, KnownPath(location));

    public string CurrencyCode()
    {
        lock (_lock)
        {
            return _currency;
        }
    }

    // Callers hold the lock.
    private IEnumerable<string> KnownPaths() =>
        new[] { _openPath }
            .OfType<string>()
            .Concat(_recentPaths)
            .Concat(_createdPaths)
            .Distinct(StringComparer.OrdinalIgnoreCase);

    private string KnownPath(string location)
    {
        lock (_lock)
        {
            return KnownPaths().FirstOrDefault(path =>
                    string.Equals(path, location, StringComparison.OrdinalIgnoreCase))
                ?? throw new InvalidOperationException($"{location} is not one of Budget Warden's budgets.");
        }
    }

    private static void WriteAtomically(string path, string json, bool overwrite)
    {
        string directory = Path.GetDirectoryName(path)
            ?? throw new IOException("The budget path has no parent folder.");
        string temporaryPath = Path.Combine(directory, $".{Path.GetFileName(path)}.{Guid.NewGuid():N}.tmp");
        try
        {
            File.WriteAllText(temporaryPath, json);
            File.Move(temporaryPath, path, overwrite);
        }
        finally
        {
            if (File.Exists(temporaryPath))
            {
                File.Delete(temporaryPath);
            }
        }
    }
}
