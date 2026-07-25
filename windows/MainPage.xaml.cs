using System.Globalization;
using Bw_core;
using BudgetWarden_Windows.Services;
using BudgetWarden_Windows.ViewModels;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.Windows.Storage.Pickers;
using CoreApi = Bw_core.Bw_core;

namespace BudgetWarden_Windows;

public sealed partial class MainPage : Page
{
    public MainPageViewModel Vm { get; } = new();

    public MainPage()
    {
        InitializeComponent();
    }

    private void MainPage_Loaded(object sender, RoutedEventArgs e) => Vm.Refresh();

    private void ShellNavigation_Loaded(object sender, RoutedEventArgs e)
    {
        if (ShellNavigation.SettingsItem is DependencyObject settingsItem)
        {
            AutomationProperties.SetAutomationId(settingsItem, "NavSettings");
        }
    }

    private void ShellNavigation_SelectionChanged(NavigationView sender, NavigationViewSelectionChangedEventArgs args)
    {
        string tag = args.IsSettingsSelected
            ? "settings"
            : (args.SelectedItemContainer?.Tag as string ?? "budget");
        Vm.Navigate(tag);
    }

    private async void NewBudget_Click(object sender, RoutedEventArgs e)
    {
        IReadOnlyList<BudgetTemplate> templates = await Vm.GetBudgetTemplatesAsync();
        TextBox titleBox = TextBox("Budget title", "NewBudgetTitleBox");
        titleBox.Text = DateTime.Now.ToString("MMMM yyyy", CultureInfo.CurrentCulture);
        ComboBox templateBox = new()
        {
            ItemsSource = templates,
            DisplayMemberPath = nameof(BudgetTemplate.DisplayName),
            SelectedIndex = 0,
        };
        AutomationProperties.SetAutomationId(templateBox, "BudgetTemplateComboBox");
        AutomationProperties.SetName(templateBox, "Budget template");

        ContentDialog dialog = Dialog(
            "New budget",
            Form(("Title", titleBox), ("Template", templateBox)),
            "Create");
        dialog.IsPrimaryButtonEnabled = true;
        if (await dialog.ShowAsync() != ContentDialogResult.Primary
            || templateBox.SelectedItem is not BudgetTemplate template)
        {
            return;
        }

        var picker = new FileSavePicker(App.WindowId)
        {
            SuggestedStartLocation = PickerLocationId.DocumentsLibrary,
            SuggestedFileName = SafeFileName(titleBox.Text),
        };
        picker.FileTypeChoices.Add("Budget Warden budget", new List<string> { ".budget" });
        PickFileResult? result = await picker.PickSaveFileAsync();
        if (result is null)
        {
            return;
        }

        await RunWithErrorDialogAsync(
            () => Vm.Store.CreateBudgetAsync(titleBox.Text, template, result.Path),
            "Budget created.");
    }

    private async void OpenBudget_Click(object sender, RoutedEventArgs e)
    {
        var picker = new FileOpenPicker(App.WindowId)
        {
            SuggestedStartLocation = PickerLocationId.DocumentsLibrary,
        };
        picker.FileTypeFilter.Add(".budget");
        PickFileResult? result = await picker.PickSingleFileAsync();
        if (result is not null)
        {
            await RunWithErrorDialogAsync(() => Vm.Store.OpenBudgetAsync(result.Path), "Budget opened.");
        }
    }

    private async void OpenRecent_Click(object sender, RoutedEventArgs e)
    {
        if (sender is Button { DataContext: RecentBudget recent })
        {
            await RunWithErrorDialogAsync(() => Vm.Store.OpenBudgetAsync(recent.Path), "Budget opened.");
        }
    }

    private async void NewCategory_Click(object sender, RoutedEventArgs e) =>
        await ShowCategoryDialogAsync(null);

    private async void EditCategory_Click(object sender, RoutedEventArgs e)
    {
        if (Vm.SelectedCategory is not null)
        {
            await ShowCategoryDialogAsync(Vm.SelectedCategory);
        }
    }

    private async Task ShowCategoryDialogAsync(CategoryRowViewModel? category)
    {
        TextBox titleBox = TextBox("Category title", "CategoryTitleBox");
        TextBox amountBox = TextBox("0.00", "CategoryPlannedAmountBox");
        ComboBox typeBox = new()
        {
            ItemsSource = CategoryTypes,
            DisplayMemberPath = nameof(CategoryTypeOption.DisplayName),
            SelectedIndex = 1,
        };
        AutomationProperties.SetAutomationId(typeBox, "CategoryTypeComboBox");
        AutomationProperties.SetName(typeBox, "Category type");

        if (category is not null)
        {
            titleBox.Text = category.Title;
            amountBox.Text = CoreApi.FormatMoneyInput(category.Category.AmountPlanned);
            typeBox.SelectedItem = CategoryTypes.First(item => item.Value == category.Category.CategoryType);
        }

        ContentDialog dialog = Dialog(
            category is null ? "New category" : "Edit category",
            Form(("Type", typeBox), ("Title", titleBox), ("Planned amount", amountBox)),
            "Save");
        void Validate(object? _, object __) => dialog.IsPrimaryButtonEnabled =
            !string.IsNullOrWhiteSpace(titleBox.Text) && IsMoney(amountBox.Text, true);
        titleBox.TextChanged += Validate;
        amountBox.TextChanged += Validate;
        Validate(null, new object());

        if (await dialog.ShowAsync() != ContentDialogResult.Primary
            || typeBox.SelectedItem is not CategoryTypeOption type)
        {
            return;
        }

        Func<Task> action = category is null
            ? () => Vm.Store.CreateCategoryAsync(titleBox.Text, amountBox.Text, type.Value)
            : () => Vm.Store.UpdateCategoryAsync(category.Id, titleBox.Text, amountBox.Text, type.Value);
        await Vm.RunAsync(action, category is null ? "Category created." : "Category updated.");
    }

    private async void NewTransaction_Click(object sender, RoutedEventArgs e) =>
        await ShowTransactionDialogAsync(null);

    private async void TransactionForCategory_Click(object sender, RoutedEventArgs e) =>
        await ShowTransactionDialogAsync(Vm.SelectedCategory);

    private async Task ShowTransactionDialogAsync(CategoryRowViewModel? initialCategory)
    {
        if (Vm.Categories.Count == 0)
        {
            await MessageAsync("No categories", "Create a category before adding a transaction.");
            return;
        }

        ComboBox categoryBox = new()
        {
            ItemsSource = Vm.Categories,
            DisplayMemberPath = nameof(CategoryRowViewModel.Title),
            SelectedItem = initialCategory ?? Vm.Categories[0],
        };
        AutomationProperties.SetAutomationId(categoryBox, "TransactionCategoryComboBox");
        AutomationProperties.SetName(categoryBox, "Transaction category");
        TextBox titleBox = TextBox("Transaction title", "TransactionTitleBox");
        TextBox amountBox = TextBox("0.00", "TransactionAmountBox");
        TextBox descriptionBox = TextBox("Optional note", "TransactionDescriptionBox");
        CalendarDatePicker datePicker = new() { Date = DateTimeOffset.Now };
        AutomationProperties.SetAutomationId(datePicker, "TransactionDatePicker");
        AutomationProperties.SetName(datePicker, "Transaction date");

        ContentDialog dialog = Dialog(
            "New transaction",
            Form(
                ("Category", categoryBox),
                ("Title", titleBox),
                ("Amount", amountBox),
                ("Date", datePicker),
                ("Description", descriptionBox)),
            "Save");
        void Validate(object? _, object __) => dialog.IsPrimaryButtonEnabled =
            categoryBox.SelectedItem is not null
            && !string.IsNullOrWhiteSpace(titleBox.Text)
            && IsMoney(amountBox.Text, false);
        titleBox.TextChanged += Validate;
        amountBox.TextChanged += Validate;
        categoryBox.SelectionChanged += Validate;
        Validate(null, new object());

        if (await dialog.ShowAsync() != ContentDialogResult.Primary
            || categoryBox.SelectedItem is not CategoryRowViewModel category)
        {
            return;
        }

        await Vm.RunAsync(
            () => Vm.Store.CreateTransactionAsync(
                category.Id,
                titleBox.Text,
                descriptionBox.Text,
                datePicker.Date ?? DateTimeOffset.Now,
                amountBox.Text),
            "Transaction created.");
    }

    private async void DeleteCategory_Click(object sender, RoutedEventArgs e)
    {
        CategoryRowViewModel? category = Vm.SelectedCategory;
        if (category is null || !await ConfirmAsync(
                $"Delete {category.Title}?",
                "This removes the category and all of its transactions.",
                "Delete category"))
        {
            return;
        }

        Vm.SelectedCategory = null;
        await Vm.RunAsync(() => Vm.Store.DeleteCategoryAsync(category.Id), "Category deleted.");
    }

    private async void DeleteTransaction_Click(object sender, RoutedEventArgs e)
    {
        TransactionRowViewModel? transaction = Vm.SelectedTransaction;
        if (transaction is null || !await ConfirmAsync(
                $"Delete {transaction.Title}?",
                "This transaction will be removed from the budget.",
                "Delete transaction"))
        {
            return;
        }

        Vm.SelectedTransaction = null;
        await Vm.RunAsync(
            () => Vm.Store.DeleteTransactionAsync(transaction.CategoryId, transaction.TransactionId),
            "Transaction deleted.");
    }

    private void CloseBudget_Click(object sender, RoutedEventArgs e)
    {
        ShellNavigation.SelectedItem = BudgetNavigationItem;
        Vm.CloseBudget();
    }

    private ContentDialog Dialog(string title, UIElement content, string primaryText) => new()
    {
        XamlRoot = XamlRoot,
        Style = Application.Current.Resources["DefaultContentDialogStyle"] as Style,
        Title = title,
        Content = content,
        PrimaryButtonText = primaryText,
        CloseButtonText = "Cancel",
        DefaultButton = ContentDialogButton.Primary,
    };

    private static StackPanel Form(params (string Label, Control Control)[] fields)
    {
        StackPanel panel = new() { Spacing = 12, MinWidth = 420 };
        foreach ((string label, Control control) in fields)
        {
            panel.Children.Add(new TextBlock
            {
                Text = label,
                Style = Application.Current.Resources["BodyStrongTextBlockStyle"] as Style,
            });
            panel.Children.Add(control);
        }
        return panel;
    }

    private static TextBox TextBox(string placeholder, string automationId)
    {
        TextBox textBox = new() { PlaceholderText = placeholder };
        AutomationProperties.SetAutomationId(textBox, automationId);
        return textBox;
    }

    private async Task<bool> ConfirmAsync(string title, string message, string primaryText)
    {
        ContentDialog dialog = Dialog(title, new TextBlock { Text = message, TextWrapping = TextWrapping.Wrap }, primaryText);
        return await dialog.ShowAsync() == ContentDialogResult.Primary;
    }

    private async Task MessageAsync(string title, string message)
    {
        ContentDialog dialog = Dialog(title, new TextBlock { Text = message, TextWrapping = TextWrapping.Wrap }, "OK");
        dialog.CloseButtonText = string.Empty;
        await dialog.ShowAsync();
    }

    private async Task RunWithErrorDialogAsync(Func<Task> action, string successMessage)
    {
        Exception? error = await Vm.RunAsync(action, successMessage);
        if (error is not null && Vm.ShowWelcome)
        {
            await MessageAsync("Budget Warden", error.Message);
        }
    }

    private static bool IsMoney(string text, bool allowZero)
    {
        try
        {
            BwMoneyAmount? amount = CoreApi.ParseMoneyAmount(text, allowZero ? 0 : null);
            return amount is BwMoneyAmount value && (allowZero || value.Value > 0);
        }
        catch (BoltException)
        {
            return false;
        }
    }

    private static string SafeFileName(string title)
    {
        string safe = string.Concat(title.Trim().Select(character =>
            Path.GetInvalidFileNameChars().Contains(character) ? '-' : character));
        return safe.EndsWith(".budget", StringComparison.OrdinalIgnoreCase) ? safe[..^7] : safe;
    }

    private static IReadOnlyList<CategoryTypeOption> CategoryTypes { get; } =
    [
        new("Income", BwCategoryType.Income),
        new("Expenses", BwCategoryType.Expenses),
        new("Savings", BwCategoryType.Savings),
        new("Debt", BwCategoryType.Debt),
    ];
}

public sealed record CategoryTypeOption(string DisplayName, BwCategoryType Value);
