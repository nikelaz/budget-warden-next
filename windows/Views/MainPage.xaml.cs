using BudgetWarden_Windows.ViewModels;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace BudgetWarden_Windows.Views;

public sealed partial class MainPage : Page
{
    public AppViewModel Vm => App.ViewModel;

    public MainPage()
    {
        InitializeComponent();
    }

    private void MainPage_Loaded(object sender, RoutedEventArgs e) =>
        Vm.Refresh();

    private void ShellNavigation_Loaded(object sender, RoutedEventArgs e)
    {
        if (ShellNavigation.SettingsItem is DependencyObject settingsItem)
        {
            AutomationProperties.SetAutomationId(settingsItem, "NavSettings");
        }
    }

    private void ShellNavigation_SelectionChanged(
        NavigationView sender,
        NavigationViewSelectionChangedEventArgs args)
    {
        string tag = args.IsSettingsSelected
            ? "settings"
            : args.SelectedItemContainer?.Tag as string ?? "budget";
        Vm.Navigate(tag);
    }

    internal async void NewBudgetFromMenu() =>
        await BudgetDialogs.CreateBudgetAsync(this, Vm);

    internal async void OpenBudgetFromMenu() =>
        await BudgetDialogs.OpenBudgetAsync(this, Vm);

    internal async void NewCategoryFromMenu() =>
        await BudgetScreen.CreateCategoryAsync();

    internal async void NewTransactionFromMenu() =>
        await TransactionsScreen.CreateTransactionAsync();
}
