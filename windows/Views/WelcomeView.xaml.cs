using BudgetWarden_Windows.ViewModels;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace BudgetWarden_Windows.Views;

public sealed partial class WelcomeView : UserControl
{
    public AppViewModel Vm => App.ViewModel;

    public WelcomeView()
    {
        InitializeComponent();
    }

    private async void NewBudget_Click(object sender, RoutedEventArgs e) =>
        await CreateBudgetAsync();

    private async void OpenBudget_Click(object sender, RoutedEventArgs e) =>
        await OpenBudgetAsync();

    private async void OpenRecent_Click(object sender, RoutedEventArgs e) =>
        await BudgetDialogs.OpenRecentAsync(this, Vm, sender);

    public Task CreateBudgetAsync() =>
        BudgetDialogs.CreateBudgetAsync(this, Vm);

    public Task OpenBudgetAsync() =>
        BudgetDialogs.OpenBudgetAsync(this, Vm);
}
