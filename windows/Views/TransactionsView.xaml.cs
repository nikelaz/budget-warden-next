using Bw_core;
using BudgetWarden_Windows.ViewModels;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using CoreApi = Bw_core.Bw_core;

namespace BudgetWarden_Windows.Views;

public sealed partial class TransactionsView : UserControl
{
    private bool _isPopulatingInspector;
    private bool _isTransactionInspectorOpen;

    public AppViewModel Vm => App.ViewModel;

    public TransactionsView()
    {
        InitializeComponent();
    }

    private void TransactionsView_Loaded(object sender, RoutedEventArgs e)
    {
        TransactionList.SelectedItem = Vm.SelectedTransaction;
        PopulateTransactionInspector(Vm.SelectedTransaction);
        SetTransactionInspectorVisibility();
    }

    private void TransactionInspectorToggle_Click(object sender, RoutedEventArgs e)
    {
        _isTransactionInspectorOpen = TransactionInspectorToggle.IsChecked == true;
        if (_isTransactionInspectorOpen
            && Vm.SelectedTransaction is null
            && Vm.Transactions.FirstOrDefault() is TransactionRowViewModel firstTransaction)
        {
            TransactionList.SelectedItem = firstTransaction;
        }

        if (Vm.SelectedTransaction is null)
        {
            CloseTransactionInspector();
            return;
        }

        SetTransactionInspectorVisibility();
    }

    private void TransactionList_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        TransactionRowViewModel? selected =
            (sender as ListView)?.SelectedItem as TransactionRowViewModel;
        Vm.SelectedTransaction = selected;
        PopulateTransactionInspector(selected);
        if (selected is not null)
        {
            if (!Vm.IsRefreshing)
            {
                _isTransactionInspectorOpen = true;
            }
            SetTransactionInspectorVisibility();
        }
    }

    private void SetTransactionInspectorVisibility()
    {
        TransactionInspectorToggle.IsChecked = _isTransactionInspectorOpen;
        TransactionInspectorSplitView.IsPaneOpen =
            _isTransactionInspectorOpen && Vm.SelectedTransaction is not null;
    }

    private void CloseTransactionInspector()
    {
        _isTransactionInspectorOpen = false;
        TransactionInspectorToggle.IsChecked = false;
        TransactionInspectorSplitView.IsPaneOpen = false;
    }

    private void PopulateTransactionInspector(TransactionRowViewModel? transaction)
    {
        _isPopulatingInspector = true;
        try
        {
            TransactionInspectorTitleBox.Text = transaction?.Title ?? string.Empty;
            TransactionInspectorDescriptionBox.Text = transaction?.Description ?? string.Empty;
            TransactionInspectorAmountBox.Text = transaction is null
                ? string.Empty
                : CoreApi.FormatMoneyInput(transaction.Transaction.Amount);
            TransactionInspectorCategoryBox.SelectedItem = transaction is null
                ? null
                : Vm.Categories.FirstOrDefault(item => item.Id == transaction.CategoryId);
            TransactionInspectorDatePicker.Date = transaction is null
                ? null
                : new DateTimeOffset(
                    transaction.Transaction.Date.Year,
                    transaction.Transaction.Date.Month,
                    transaction.Transaction.Date.Day,
                    0,
                    0,
                    0,
                    TimeSpan.Zero);
            TransactionInspectorApplyButton.IsEnabled = false;
        }
        finally
        {
            _isPopulatingInspector = false;
        }
    }

    private void TransactionInspectorField_Changed(object sender, TextChangedEventArgs e) =>
        UpdateTransactionApplyState();

    private void TransactionInspectorField_Changed(object sender, SelectionChangedEventArgs e) =>
        UpdateTransactionApplyState();

    private void TransactionInspectorField_Changed(
        object sender,
        CalendarDatePickerDateChangedEventArgs e) =>
        UpdateTransactionApplyState();

    private void UpdateTransactionApplyState()
    {
        if (_isPopulatingInspector)
        {
            return;
        }

        TransactionRowViewModel? transaction = Vm.SelectedTransaction;
        if (transaction is null
            || TransactionInspectorCategoryBox.SelectedItem is not CategoryRowViewModel category
            || TransactionInspectorDatePicker.Date is not DateTimeOffset date
            || string.IsNullOrWhiteSpace(TransactionInspectorTitleBox.Text)
            || !BudgetDialogs.IsMoney(TransactionInspectorAmountBox.Text, false))
        {
            TransactionInspectorApplyButton.IsEnabled = false;
            return;
        }

        string title = TransactionInspectorTitleBox.Text.Trim();
        string description = TransactionInspectorDescriptionBox.Text.Trim();
        BwMoneyAmount amount =
            CoreApi.ParseMoneyAmount(TransactionInspectorAmountBox.Text, null)!.Value;
        BwDate coreDate = new(date.Year, date.Month, date.Day);
        TransactionInspectorApplyButton.IsEnabled =
            category.Id != transaction.CategoryId
            || title != transaction.Transaction.Title
            || description != transaction.Transaction.Description
            || coreDate != transaction.Transaction.Date
            || amount != transaction.Transaction.Amount;
    }

    private async void ApplyTransactionInspector_Click(object sender, RoutedEventArgs e)
    {
        TransactionRowViewModel? transaction = Vm.SelectedTransaction;
        if (transaction is null
            || TransactionInspectorCategoryBox.SelectedItem is not CategoryRowViewModel category
            || TransactionInspectorDatePicker.Date is not DateTimeOffset date
            || !TransactionInspectorApplyButton.IsEnabled)
        {
            return;
        }

        Exception? error = await Vm.RunAsync(
            () => Vm.UpdateTransactionAsync(
                transaction.CategoryId,
                category.Id,
                transaction.TransactionId,
                TransactionInspectorTitleBox.Text,
                TransactionInspectorDescriptionBox.Text,
                date,
                TransactionInspectorAmountBox.Text),
            "Transaction saved.");
        if (error is null)
        {
            TransactionInspectorApplyButton.IsEnabled = false;
        }
    }

    private async void NewTransaction_Click(object sender, RoutedEventArgs e) =>
        await CreateTransactionAsync();

    private async void DeleteTransaction_Click(object sender, RoutedEventArgs e)
    {
        TransactionRowViewModel? transaction = Vm.SelectedTransaction;
        if (transaction is null
            || !await BudgetDialogs.ConfirmAsync(
                this,
                $"Delete {transaction.Title}?",
                "This transaction will be removed from the budget.",
                "Delete transaction"))
        {
            return;
        }

        Vm.SelectedTransaction = null;
        await Vm.RunAsync(
            () => Vm.DeleteTransactionAsync(
                transaction.CategoryId,
                transaction.TransactionId),
            "Transaction deleted.");
    }

    public Task CreateTransactionAsync() =>
        BudgetDialogs.ShowTransactionAsync(this, Vm);
}
