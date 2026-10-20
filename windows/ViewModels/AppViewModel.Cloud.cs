using System.Collections.ObjectModel;
using System.Net.Http.Headers;
using System.Reflection;
using Bw_core;
using CommunityToolkit.Mvvm.ComponentModel;
using Microsoft.UI.Dispatching;
using Windows.Security.Credentials;
using CoreApi = Bw_core.Bw_core;

namespace BudgetWarden_Windows.ViewModels;

/// <summary>
/// Google Drive budgets: sign-in, listing (including budgets others shared
/// with the user), opening, sync after saves, and sharing. A cloud budget
/// opens from a working copy under local app data and saves like any other.
/// </summary>
public sealed partial class AppViewModel
{
    private const int SignInTimeoutSeconds = 300;

    private BwGoogleDrive? _drive;
    private BwGoogleLoopbackReceiver? _signIn;
    private DispatcherQueueTimer? _cloudSyncTimer;
    private readonly HashSet<string> _syncing = [];
    private readonly HashSet<string> _syncAgain = [];

    public ObservableCollection<CloudBudgetItem> CloudBudgets { get; } = [];

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(ShowGoogleDriveSignIn))]
    public partial bool IsGoogleDriveConfigured { get; private set; }

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(ShowGoogleDriveSignIn))]
    [NotifyPropertyChangedFor(nameof(CanCreateInGoogleDrive))]
    public partial bool IsGoogleDriveSignedIn { get; private set; }

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(GoogleDriveSignInText))]
    public partial bool IsGoogleDriveSigningIn { get; private set; }

    [ObservableProperty]
    public partial string GoogleDriveAccount { get; private set; } = string.Empty;

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(HasGoogleDriveError))]
    public partial string? GoogleDriveError { get; private set; }

    [ObservableProperty]
    public partial bool IsGoogleDriveRefreshing { get; private set; }

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(CanShareOpenBudget))]
    public partial CloudBudgetItem? OpenCloudBudget { get; private set; }

    public bool ShowGoogleDriveSignIn => IsGoogleDriveConfigured && !IsGoogleDriveSignedIn;
    public bool CanCreateInGoogleDrive => IsGoogleDriveSignedIn;
    public bool HasGoogleDriveError => GoogleDriveError is not null;
    public bool CanShareOpenBudget => OpenCloudBudget?.CanShare == true;
    public string GoogleDriveSignInText => IsGoogleDriveSigningIn ? "Continue in your browser…" : "Connect Google Drive";

    private void InitializeCloud()
    {
        string cache = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "Budget Warden",
            "Cloud");
        _drive = new BwGoogleDrive(new BwGoogleDriveConfig(
            BuildSetting("BUDGET_WARDEN_GOOGLE_CLIENT_ID", "BWGoogleClientId") ?? string.Empty,
            BuildSetting("BUDGET_WARDEN_GOOGLE_CLIENT_SECRET", "BWGoogleClientSecret"),
            cache,
            "Budget Warden"));
        _drive.Connect(new HttpClientTransport(), new PasswordVaultCredentialStore());
        IsGoogleDriveConfigured = _drive.IsConfigured();
        RefreshGoogleDriveAccount();
        ShowCloudBudgets(_drive.CachedBudgets());

        // The view model is created on the UI thread, before App.DispatcherQueue is set.
        if (DispatcherQueue.GetForCurrentThread() is { } dispatcher)
        {
            // Pull other people's changes into an open cloud budget.
            _cloudSyncTimer = dispatcher.CreateTimer();
            _cloudSyncTimer.Interval = TimeSpan.FromMinutes(1);
            _cloudSyncTimer.Tick += (_, _) => SyncCloudBudget(CurrentBudget?.Url);
            _cloudSyncTimer.Start();
        }

        _ = RefreshCloudBudgetsAsync();
    }

    /// <summary>A setting from the environment, else from the build (MSBuild property).</summary>
    private static string? BuildSetting(string environmentVariable, string metadataKey)
    {
        string? value = Environment.GetEnvironmentVariable(environmentVariable);
        if (string.IsNullOrWhiteSpace(value))
        {
            value = typeof(AppViewModel).Assembly
                .GetCustomAttributes<AssemblyMetadataAttribute>()
                .FirstOrDefault(attribute => attribute.Key == metadataKey)?.Value;
        }

        return string.IsNullOrWhiteSpace(value) ? null : value.Trim();
    }

    public bool IsCloudBudgetPath(string? path) =>
        path is not null && _drive?.IsCloudPath(path) == true;

    public async Task SignInToGoogleDriveAsync()
    {
        if (_drive is null || IsGoogleDriveSigningIn)
        {
            return;
        }

        BwGoogleDrive drive = _drive;
        BwGoogleLoopbackReceiver receiver = new();
        _signIn = receiver;
        IsGoogleDriveSigningIn = true;
        GoogleDriveError = null;
        try
        {
            string redirect = receiver.Start();
            BwGoogleSignInRequest request = drive.BeginSignIn(redirect);
            await Windows.System.Launcher.LaunchUriAsync(new Uri(request.AuthorizationUrl));
            string callback = await Task.Run(() => receiver.WaitForRedirect(SignInTimeoutSeconds));
            await Task.Run(() => drive.CompleteSignIn(callback));
            RefreshGoogleDriveAccount();
            await RefreshCloudBudgetsAsync();
        }
        catch (BoltException error)
        {
            string message = CoreApi.CloudErrorMessage(error.Message);
            if (message != "Google sign-in was cancelled.")
            {
                GoogleDriveError = message;
            }
        }
        finally
        {
            receiver.Dispose();
            _signIn = null;
            IsGoogleDriveSigningIn = false;
        }
    }

    public void CancelGoogleDriveSignIn() => _signIn?.Cancel();

    public async Task SignOutOfGoogleDriveAsync()
    {
        if (_drive is not { } drive)
        {
            return;
        }

        await Task.Run(drive.SignOut);
        CloudBudgets.Clear();
        OpenCloudBudget = null;
        GoogleDriveError = null;
        RefreshGoogleDriveAccount();
    }

    private void RefreshGoogleDriveAccount()
    {
        IsGoogleDriveSignedIn = _drive?.IsSignedIn() == true;
        BwGoogleAccount? account = _drive?.Account();
        GoogleDriveAccount = account?.Email ?? account?.DisplayName ?? string.Empty;
    }

    public async Task RefreshCloudBudgetsAsync()
    {
        if (_drive is not { } drive || !IsGoogleDriveSignedIn || IsGoogleDriveRefreshing)
        {
            return;
        }

        IsGoogleDriveRefreshing = true;
        try
        {
            ShowCloudBudgets(await Task.Run(drive.ListBudgets));
            GoogleDriveError = null;
        }
        catch (BoltException error)
        {
            ReportCloudError(error);
        }
        finally
        {
            IsGoogleDriveRefreshing = false;
        }
    }

    public async Task OpenCloudBudgetAsync(CloudBudgetItem budget)
    {
        BwGoogleDrive drive = _drive ?? throw new InvalidOperationException("Google Drive is not available.");
        BwCloudSyncResult result = await Task.Run(() => drive.OpenBudget(budget.Id));
        RememberCloudBudget(result.Budget);
        await OpenBudgetAsync(result.LocalPath);
    }

    /// <summary>Uploads a new budget to Google Drive and opens it.</summary>
    public async Task CreateCloudBudgetAsync(string title, BudgetTemplate template)
    {
        BwGoogleDrive drive = _drive ?? throw new InvalidOperationException("Google Drive is not available.");
        string trimmedTitle = title.Trim();
        if (trimmedTitle.Length == 0)
        {
            throw new ArgumentException("A budget title is required.", nameof(title));
        }

        BwBudget budget = template.PreviousBudget is BwBudget previous
            ? CoreApi.BudgetFromPreviousBudget(previous, trimmedTitle)
            : CoreApi.BudgetFromTemplateId(
                template.TemplateId ?? throw new InvalidOperationException("Choose a budget template."),
                trimmedTitle);
        string json = CoreApi.EncodeBudget(budget);
        BwCloudBudget created = await Task.Run(() => drive.CreateBudget($"{trimmedTitle}.budget", json));
        RememberCloudBudget(created);
        await OpenBudgetAsync(created.LocalPath ?? throw new IOException("The new budget has no local copy."));
    }

    /// <summary>
    /// Syncs the working copy at <paramref name="path"/>. Requests made while
    /// that budget syncs run once more afterwards, so the latest save is uploaded.
    /// </summary>
    private void SyncCloudBudget(string? path)
    {
        if (_drive is not { } drive || path is null || drive.BudgetIdForPath(path) is not string id)
        {
            return;
        }

        if (!_syncing.Add(id))
        {
            _syncAgain.Add(id);
            return;
        }

        _ = SyncLoopAsync(drive, id);
    }

    private async Task SyncLoopAsync(BwGoogleDrive drive, string id)
    {
        do
        {
            _syncAgain.Remove(id);
            try
            {
                BwCloudSyncResult result = await Task.Run(() => drive.SyncBudget(id));
                RememberCloudBudget(result.Budget);
                GoogleDriveError = null;
                if (result.LocalChanged && IsCurrentBudgetPath(result.LocalPath))
                {
                    BwBudget reloaded = await ReadBudgetAsync(result.LocalPath);
                    if (IsCurrentBudgetPath(result.LocalPath) && reloaded.RevisionId != CurrentBudget?.RevisionId)
                    {
                        CurrentBudget = reloaded;
                    }
                }
            }
            catch (Exception error) when (error is BoltException or IOException)
            {
                // Sync runs again after the next save or timer tick.
                if (error is BoltException boltError)
                {
                    ReportCloudError(boltError);
                }
            }
        }
        while (_syncAgain.Contains(id));

        _syncing.Remove(id);
    }

    public Task<BwCloudShare[]> ListSharesAsync(CloudBudgetItem budget)
    {
        BwGoogleDrive drive = _drive ?? throw new InvalidOperationException("Google Drive is not available.");
        return Task.Run(() => drive.ListShares(budget.Id));
    }

    public async Task ShareCloudBudgetAsync(CloudBudgetItem budget, string email, bool canEdit, string? message)
    {
        BwGoogleDrive drive = _drive ?? throw new InvalidOperationException("Google Drive is not available.");
        BwCloudShareRole role = canEdit ? BwCloudShareRole.Writer : BwCloudShareRole.Reader;
        await Task.Run(() => drive.ShareBudget(budget.Id, email, role, string.IsNullOrWhiteSpace(message) ? null : message));
        budget.Update(budget.Budget with { IsShared = true });
    }

    public Task RemoveShareAsync(CloudBudgetItem budget, BwCloudShare share)
    {
        BwGoogleDrive drive = _drive ?? throw new InvalidOperationException("Google Drive is not available.");
        return Task.Run(() => drive.RemoveShare(budget.Id, share.Id));
    }

    /// <summary>Removes the core's sign-in marker from a cloud error message.</summary>
    public static string CloudMessage(Exception error) =>
        error is BoltException ? CoreApi.CloudErrorMessage(error.Message) : error.Message;

    private void ReportCloudError(BoltException error)
    {
        GoogleDriveError = CoreApi.CloudErrorMessage(error.Message);
        if (CoreApi.IsCloudSignInRequired(error.Message))
        {
            RefreshGoogleDriveAccount();
        }
    }

    private void ShowCloudBudgets(IEnumerable<BwCloudBudget> budgets)
    {
        CloudBudgets.Clear();
        foreach (BwCloudBudget budget in budgets)
        {
            CloudBudgets.Add(new CloudBudgetItem(budget));
        }

        UpdateOpenCloudBudget();
    }

    private void RememberCloudBudget(BwCloudBudget budget)
    {
        if (CloudBudgets.FirstOrDefault(item => item.Id == budget.Id) is { } existing)
        {
            existing.Update(budget);
        }
        else
        {
            CloudBudgets.Insert(0, new CloudBudgetItem(budget));
        }

        UpdateOpenCloudBudget();
    }

    private void UpdateOpenCloudBudget()
    {
        string? id = CurrentBudget?.Url is string path ? _drive?.BudgetIdForPath(path) : null;
        OpenCloudBudget = id is null ? null : CloudBudgets.FirstOrDefault(item => item.Id == id);
    }
}

/// <summary>A Google Drive budget as the welcome page shows it.</summary>
public sealed partial class CloudBudgetItem(BwCloudBudget budget) : ObservableObject
{
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(Title))]
    [NotifyPropertyChangedFor(nameof(Location))]
    [NotifyPropertyChangedFor(nameof(CanShare))]
    public partial BwCloudBudget Budget { get; private set; } = budget;

    public string Id => Budget.Id;
    public string Title => Budget.Title;
    public bool CanShare => Budget.CanShare;

    /// <summary>"Shared by Ana", "Google Drive · Shared", or "Google Drive".</summary>
    public string Location
    {
        get
        {
            string who = Budget.OwnerName ?? Budget.OwnerEmail ?? "someone";
            return (Budget.SharedWithMe, Budget.CanEdit, Budget.IsShared) switch
            {
                (true, true, _) => $"Shared by {who}",
                (true, false, _) => $"Shared by {who} · View only",
                (false, _, true) => "Google Drive · Shared",
                _ => "Google Drive",
            };
        }
    }

    public void Update(BwCloudBudget budget) => Budget = budget;
}

/// <summary>Performs the core's Google Drive requests with HttpClient.</summary>
internal sealed class HttpClientTransport : BwHttpClient
{
    private static readonly HttpClient Client = new() { Timeout = TimeSpan.FromSeconds(60) };

    public BwHttpResponse Execute(BwHttpRequest request)
    {
        using HttpRequestMessage message = new(new HttpMethod(request.Method), request.Url);
        string? contentType = null;
        foreach (BwHttpHeader header in request.Headers)
        {
            if (string.Equals(header.Name, "Content-Type", StringComparison.OrdinalIgnoreCase))
            {
                contentType = header.Value;
            }
            else
            {
                message.Headers.TryAddWithoutValidation(header.Name, header.Value);
            }
        }

        if (request.Body is string body)
        {
            message.Content = new StringContent(body);
            if (contentType is not null)
            {
                message.Content.Headers.ContentType = MediaTypeHeaderValue.Parse(contentType);
            }
        }

        try
        {
            using HttpResponseMessage response = Client.Send(message);
            using StreamReader reader = new(response.Content.ReadAsStream());
            BwHttpHeader[] headers = response.Headers
                .Concat(response.Content.Headers)
                .SelectMany(header => header.Value.Select(value => new BwHttpHeader(header.Key, value)))
                .ToArray();
            return new BwHttpResponse((int)response.StatusCode, headers, reader.ReadToEnd());
        }
        catch (HttpRequestException error)
        {
            throw new IOException($"Could not reach Google Drive: {error.Message}", error);
        }
        catch (TaskCanceledException error)
        {
            throw new IOException("Google Drive did not respond in time.", error);
        }
    }
}

/// <summary>Keeps the Google sign-in in the Windows Credential Locker.</summary>
internal sealed class PasswordVaultCredentialStore : BwGoogleCredentialStore
{
    private const string Resource = "Budget Warden Google Drive";
    private const string UserName = "google-drive";

    public string? LoadCredentials()
    {
        try
        {
            PasswordCredential credential = new PasswordVault().Retrieve(Resource, UserName);
            credential.RetrievePassword();
            return credential.Password;
        }
        catch (Exception)
        {
            // The vault throws when nothing is stored.
            return null;
        }
    }

    public void SaveCredentials(string credentials)
    {
        DeleteCredentials();
        new PasswordVault().Add(new PasswordCredential(Resource, UserName, credentials));
    }

    public void DeleteCredentials()
    {
        try
        {
            PasswordVault vault = new();
            vault.Remove(vault.Retrieve(Resource, UserName));
        }
        catch (Exception)
        {
            // Nothing was stored.
        }
    }
}
