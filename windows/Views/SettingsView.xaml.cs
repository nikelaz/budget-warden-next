using System.Collections.ObjectModel;
using BudgetWarden_Windows.ViewModels;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace BudgetWarden_Windows.Views;

public sealed partial class SettingsView : UserControl
{
    public AppViewModel Vm => App.ViewModel;

    public SettingsView()
    {
        InitializeComponent();
        CurrencyBox.Text = Vm.SelectedCurrency.DisplayName;
        CurrencyBox.ItemsSource = new ObservableCollection<string>(
            Vm.CurrencyOptions.Select(currency => currency.DisplayName));
    }

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
            currencyBox.Text = Vm.SelectedCurrency.DisplayName;
        }
    }

    private void SelectCurrency(AutoSuggestBox sender, CurrencyOption currency)
    {
        Vm.SelectedCurrency = currency;
        sender.Text = currency.DisplayName;
    }

    private CurrencyOption? CurrencyFromDisplayName(string displayName) =>
        Vm.CurrencyOptions.FirstOrDefault(currency =>
            currency.DisplayName.Equals(displayName, StringComparison.Ordinal));
}
