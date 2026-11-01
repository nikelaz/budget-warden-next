using System.Collections.ObjectModel;
using BudgetWarden_Windows.ViewModels;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Windows.ApplicationModel.DataTransfer;

namespace BudgetWarden_Windows.Views;

public sealed partial class SettingsView : UserControl
{
    public AppViewModel Vm => App.ViewModel;

    public SettingsView()
    {
        InitializeComponent();
        foreach (AutoSuggestBox box in new[] { BudgetCurrencyBox, DefaultCurrencyBox })
        {
            box.Text = SelectedCurrency(box).DisplayName;
            box.ItemsSource = new ObservableCollection<string>(
                Vm.CurrencyOptions.Select(currency => currency.DisplayName));
        }

        // Show the newly opened budget's currency.
        Vm.PropertyChanged += (_, args) =>
        {
            if (args.PropertyName == nameof(AppViewModel.BudgetCurrency)
                && BudgetCurrencyBox.FocusState == FocusState.Unfocused)
            {
                BudgetCurrencyBox.Text = Vm.BudgetCurrency.DisplayName;
            }
        };
    }

    private CurrencyOption SelectedCurrency(AutoSuggestBox box) =>
        box == BudgetCurrencyBox ? Vm.BudgetCurrency : Vm.DefaultCurrency;

    private void CurrencyBox_TextChanged(
        AutoSuggestBox sender,
        AutoSuggestBoxTextChangedEventArgs args)
    {
        if (args.Reason != AutoSuggestionBoxTextChangeReason.UserInput)
        {
            return;
        }

        string[] terms = sender.Text.Split(
            ' ',
            StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);

        sender.ItemsSource = new ObservableCollection<string>(
            Vm.CurrencyOptions
                .Where(currency => terms.All(term =>
                    currency.Code.Contains(term, StringComparison.OrdinalIgnoreCase)
                    || currency.Name.Contains(term, StringComparison.OrdinalIgnoreCase)))
                .OrderByDescending(currency =>
                    currency.Code.Equals(sender.Text.Trim(), StringComparison.OrdinalIgnoreCase))
                .ThenByDescending(currency =>
                    currency.Name.StartsWith(sender.Text.Trim(), StringComparison.OrdinalIgnoreCase))
                .Take(25)
                .Select(currency => currency.DisplayName));
    }

    private void CurrencyBox_SuggestionChosen(
        AutoSuggestBox sender,
        AutoSuggestBoxSuggestionChosenEventArgs args)
    {
        if (args.SelectedItem is string displayName
            && CurrencyFromDisplayName(displayName) is CurrencyOption currency)
        {
            SelectCurrency(sender, currency);
        }
    }

    private void CurrencyBox_QuerySubmitted(
        AutoSuggestBox sender,
        AutoSuggestBoxQuerySubmittedEventArgs args)
    {
        if (args.ChosenSuggestion is string displayName
            && CurrencyFromDisplayName(displayName) is CurrencyOption chosenCurrency)
        {
            SelectCurrency(sender, chosenCurrency);
            return;
        }

        string query = sender.Text.Trim();
        CurrencyOption? exactMatch = Vm.CurrencyOptions.FirstOrDefault(currency =>
            currency.Code.Equals(query, StringComparison.OrdinalIgnoreCase)
            || currency.Name.Equals(query, StringComparison.OrdinalIgnoreCase)
            || currency.DisplayName.Equals(query, StringComparison.OrdinalIgnoreCase));

        if (exactMatch is not null)
        {
            SelectCurrency(sender, exactMatch);
        }
    }

    private void CurrencyBox_LostFocus(object sender, RoutedEventArgs e)
    {
        if (sender is AutoSuggestBox currencyBox)
        {
            currencyBox.Text = SelectedCurrency(currencyBox).DisplayName;
        }
    }

    private async void SelectCurrency(AutoSuggestBox sender, CurrencyOption currency)
    {
        sender.Text = currency.DisplayName;
        if (sender != BudgetCurrencyBox)
        {
            Vm.DefaultCurrency = currency;
            return;
        }

        try
        {
            await Vm.SetBudgetCurrencyAsync(currency);
        }
        catch (Exception error)
        {
            sender.Text = Vm.BudgetCurrency.DisplayName;
            await BudgetDialogs.ShowMessageAsync(this, "Could not change the currency", error.Message);
        }
    }

    // Bindings also raise Toggled; only forward changes the user made.
    private void McpEnabledSwitch_Toggled(object sender, RoutedEventArgs e)
    {
        if (McpEnabledSwitch.IsOn != Vm.IsMcpServerEnabled)
        {
            Vm.SetMcpServerEnabled(McpEnabledSwitch.IsOn);
        }
    }

    private void McpNetworkSwitch_Toggled(object sender, RoutedEventArgs e)
    {
        if (McpNetworkSwitch.IsOn != Vm.McpServerAllowsNetwork)
        {
            Vm.SetMcpServerAllowsNetwork(McpNetworkSwitch.IsOn);
        }
    }

    private void CopyMcpUrl_Click(object sender, RoutedEventArgs e)
    {
        if (Vm.McpServerUrl is not string url)
        {
            return;
        }

        DataPackage package = new();
        package.SetText(url);
        Clipboard.SetContent(package);
    }

    private async void SignInGoogleDrive_Click(object sender, RoutedEventArgs e) =>
        await Vm.SignInToGoogleDriveAsync();

    private async void SignOutGoogleDrive_Click(object sender, RoutedEventArgs e) =>
        await Vm.SignOutOfGoogleDriveAsync();

    private void RegenerateMcpUrl_Click(object sender, RoutedEventArgs e) =>
        Vm.RegenerateMcpServerUrl();

    private CurrencyOption? CurrencyFromDisplayName(string displayName) =>
        Vm.CurrencyOptions.FirstOrDefault(currency =>
            currency.DisplayName.Equals(displayName, StringComparison.Ordinal));
}
