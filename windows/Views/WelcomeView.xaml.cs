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

    private async void ConnectGoogleDrive_Click(object sender, RoutedEventArgs e) =>
        await Vm.SignInToGoogleDriveAsync();

    private async void RefreshGoogleDrive_Click(object sender, RoutedEventArgs e) =>
        await Vm.RefreshCloudBudgetsAsync();

    private async void AddSharedBudget_Click(object sender, RoutedEventArgs e) =>
        await Vm.AddSharedBudgetAsync();

    private async void OpenCloudBudget_Click(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { DataContext: CloudBudgetItem budget })
        {
            await BudgetDialogs.OpenCloudBudgetAsync(this, Vm, budget);
        }
    }

    private async void ShareCloudBudget_Click(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { DataContext: CloudBudgetItem budget })
        {
            await BudgetDialogs.ShareCloudBudgetAsync(this, Vm, budget);
        }
    }

    public Task CreateBudgetAsync() =>
        BudgetDialogs.CreateBudgetAsync(this, Vm);

    public Task OpenBudgetAsync() =>
        BudgetDialogs.OpenBudgetAsync(this, Vm);
}
