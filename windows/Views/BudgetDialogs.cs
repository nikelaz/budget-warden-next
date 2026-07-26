using System.Globalization;
using Bw_core;
using BudgetWarden_Windows.ViewModels;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.Windows.Storage.Pickers;
using CoreApi = Bw_core.Bw_core;

namespace BudgetWarden_Windows.Views;

internal static class BudgetDialogs
{
    public static async Task CreateBudgetAsync(
        FrameworkElement owner,
        AppViewModel viewModel,
        FlyoutBase? sourceFlyout = null)
    {
        sourceFlyout?.Hide();
        IReadOnlyList<BudgetTemplate> templates = await viewModel.GetBudgetTemplatesAsync();
        TextBox titleBox = CreateTextBox("Budget title", "NewBudgetTitleBox");
        titleBox.Text = DateTime.Now.ToString("MMMM yyyy", CultureInfo.CurrentCulture);
        ComboBox templateBox = new()
        {
            ItemsSource = templates,
            DisplayMemberPath = nameof(BudgetTemplate.DisplayName),
            SelectedIndex = 0,
        };
        AutomationProperties.SetAutomationId(templateBox, "BudgetTemplateComboBox");
        AutomationProperties.SetName(templateBox, "Budget template");

        ContentDialog dialog = CreateDialog(
            owner,
            "New budget",
            CreateForm(("Title", titleBox), ("Template", templateBox)),
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
        picker.FileTypeChoices.Add("Budget Warden budget", [".budget"]);
        PickFileResult? result = await picker.PickSaveFileAsync();
        if (result is null)
        {
            return;
        }

        await RunWithErrorDialogAsync(
            owner,
            viewModel,
            () => viewModel.CreateBudgetAsync(titleBox.Text, template, result.Path),
            "Budget created.");
    }

    public static async Task OpenBudgetAsync(FrameworkElement owner, AppViewModel viewModel)
    {
        var picker = new FileOpenPicker(App.WindowId)
        {
            SuggestedStartLocation = PickerLocationId.DocumentsLibrary,
        };
        picker.FileTypeFilter.Add(".budget");
        PickFileResult? result = await picker.PickSingleFileAsync();
        if (result is not null)
        {
            await RunWithErrorDialogAsync(
                owner,
                viewModel,
                () => viewModel.OpenBudgetAsync(result.Path),
                "Budget opened.");
        }
    }

    public static async Task OpenRecentAsync(
        FrameworkElement owner,
        AppViewModel viewModel,
        object sender,
        FlyoutBase? sourceFlyout = null)
    {
        string? path = sender switch
        {
            Button { Tag: string taggedPath } => taggedPath,
            Button { DataContext: RecentBudget recent } => recent.Path,
            _ => null,
        };
        if (path is null)
        {
            return;
        }

        sourceFlyout?.Hide();
        await RunWithErrorDialogAsync(
            owner,
            viewModel,
            () => viewModel.OpenBudgetAsync(path),
            "Budget opened.");
    }

    public static async Task ShowCategoryAsync(
        FrameworkElement owner,
        AppViewModel viewModel,
        CategoryRowViewModel? category = null,
        BwCategoryType? initialType = null)
    {
        TextBox titleBox = CreateTextBox("Category title", "CategoryTitleBox");
        TextBox amountBox = CreateTextBox("0.00", "CategoryPlannedAmountBox");
        TextBox accumulatedBox = CreateTextBox("0.00", "CategoryAccumulatedAmountBox");
        ComboBox typeBox = new()
        {
            ItemsSource = viewModel.CategoryTypes,
            DisplayMemberPath = nameof(CategoryTypeOption.DisplayName),
            SelectedIndex = 1,
        };
        AutomationProperties.SetAutomationId(typeBox, "CategoryTypeComboBox");
        AutomationProperties.SetName(typeBox, "Category type");

        if (category is not null)
        {
            titleBox.Text = category.Title;
            amountBox.Text = CoreApi.FormatMoneyInput(category.Category.AmountPlanned);
            accumulatedBox.Text = CoreApi.FormatMoneyInput(category.Category.AmountAccumulated);
            typeBox.SelectedItem = viewModel.CategoryTypes.First(item =>
                item.Value == category.Category.CategoryType);
        }
        else if (initialType is BwCategoryType categoryType)
        {
            typeBox.SelectedItem = viewModel.CategoryTypes.First(item => item.Value == categoryType);
            typeBox.IsEnabled = false;
        }

        TextBlock accumulatedLabel = new()
        {
            Text = "Accumulated",
            Style = Application.Current.Resources["BodyStrongTextBlockStyle"] as Style,
        };
        StackPanel form = CreateForm(
            ("Type", typeBox),
            ("Title", titleBox),
            ("Planned amount", amountBox));
        form.Children.Add(accumulatedLabel);
        form.Children.Add(accumulatedBox);

        void UpdateAccumulatedField()
        {
            CategoryTypeOption? selectedType = typeBox.SelectedItem as CategoryTypeOption;
            bool show = selectedType?.HasAccumulated == true;
            accumulatedLabel.Visibility = show ? Visibility.Visible : Visibility.Collapsed;
            accumulatedBox.Visibility = show ? Visibility.Visible : Visibility.Collapsed;
            accumulatedLabel.Text = selectedType?.Value == BwCategoryType.Debt
                ? "Leftover debt"
                : "Accumulated";
        }

        ContentDialog dialog = CreateDialog(
            owner,
            category is null ? "New category" : "Edit category",
            form,
            "Save");
        void Validate(object? _, object __) => dialog.IsPrimaryButtonEnabled =
            !string.IsNullOrWhiteSpace(titleBox.Text)
            && IsMoney(amountBox.Text, true)
            && typeBox.SelectedItem is CategoryTypeOption selectedType
            && (!selectedType.HasAccumulated || IsMoney(accumulatedBox.Text, true));
        titleBox.TextChanged += Validate;
        amountBox.TextChanged += Validate;
        accumulatedBox.TextChanged += Validate;
        typeBox.SelectionChanged += (_, _) =>
        {
            UpdateAccumulatedField();
            Validate(null, new object());
        };
        UpdateAccumulatedField();
        Validate(null, new object());

        if (await dialog.ShowAsync() != ContentDialogResult.Primary
            || typeBox.SelectedItem is not CategoryTypeOption type)
        {
            return;
        }

        Func<Task> action = category is null
            ? () => viewModel.CreateCategoryAsync(
                titleBox.Text,
                amountBox.Text,
                accumulatedBox.Text,
                type.Value)
            : () => viewModel.UpdateCategoryAsync(
                category.Id,
                titleBox.Text,
                amountBox.Text,
                accumulatedBox.Text,
                type.Value);
        await viewModel.RunAsync(
            action,
            category is null ? "Category created." : "Category updated.");
    }

    public static async Task ShowTransactionAsync(
        FrameworkElement owner,
        AppViewModel viewModel,
        CategoryRowViewModel? initialCategory = null)
    {
        if (viewModel.Categories.Count == 0)
        {
            await ShowMessageAsync(
                owner,
                "No categories",
                "Create a category before adding a transaction.");
            return;
        }

        ComboBox categoryBox = new()
        {
            ItemsSource = viewModel.Categories,
            DisplayMemberPath = nameof(CategoryRowViewModel.Title),
            SelectedItem = initialCategory ?? viewModel.Categories[0],
        };
        AutomationProperties.SetAutomationId(categoryBox, "TransactionCategoryComboBox");
        AutomationProperties.SetName(categoryBox, "Transaction category");
        TextBox titleBox = CreateTextBox("Transaction title", "TransactionTitleBox");
        TextBox amountBox = CreateTextBox("0.00", "TransactionAmountBox");
        TextBox descriptionBox = CreateTextBox("Optional note", "TransactionDescriptionBox");
        CalendarDatePicker datePicker = new() { Date = DateTimeOffset.Now };
        AutomationProperties.SetAutomationId(datePicker, "TransactionDatePicker");
        AutomationProperties.SetName(datePicker, "Transaction date");

        ContentDialog dialog = CreateDialog(
            owner,
            "New transaction",
            CreateForm(
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

        await viewModel.RunAsync(
            () => viewModel.CreateTransactionAsync(
                category.Id,
                titleBox.Text,
                descriptionBox.Text,
                datePicker.Date ?? DateTimeOffset.Now,
                amountBox.Text),
            "Transaction created.");
    }

    public static async Task<bool> ConfirmAsync(
        FrameworkElement owner,
        string title,
        string message,
        string primaryText)
    {
        ContentDialog dialog = CreateDialog(
            owner,
            title,
            new TextBlock { Text = message, TextWrapping = TextWrapping.Wrap },
            primaryText);
        return await dialog.ShowAsync() == ContentDialogResult.Primary;
    }

    public static bool IsMoney(string text, bool allowZero)
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

    private static ContentDialog CreateDialog(
        FrameworkElement owner,
        string title,
        UIElement content,
        string primaryText) => new()
    {
        XamlRoot = owner.XamlRoot,
        Style = Application.Current.Resources["DefaultContentDialogStyle"] as Style,
        Title = title,
        Content = content,
        PrimaryButtonText = primaryText,
        CloseButtonText = "Cancel",
        DefaultButton = ContentDialogButton.Primary,
    };

    private static StackPanel CreateForm(params (string Label, Control Control)[] fields)
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

    private static TextBox CreateTextBox(string placeholder, string automationId)
    {
        TextBox textBox = new() { PlaceholderText = placeholder };
        AutomationProperties.SetAutomationId(textBox, automationId);
        return textBox;
    }

    private static async Task ShowMessageAsync(
        FrameworkElement owner,
        string title,
        string message)
    {
        ContentDialog dialog = CreateDialog(
            owner,
            title,
            new TextBlock { Text = message, TextWrapping = TextWrapping.Wrap },
            "OK");
        dialog.CloseButtonText = string.Empty;
        await dialog.ShowAsync();
    }

    private static async Task RunWithErrorDialogAsync(
        FrameworkElement owner,
        AppViewModel viewModel,
        Func<Task> action,
        string successMessage)
    {
        Exception? error = await viewModel.RunAsync(action, successMessage);
        if (error is not null && viewModel.ShowWelcome)
        {
            await ShowMessageAsync(owner, "Budget Warden", error.Message);
        }
    }

    private static string SafeFileName(string title)
    {
        string safe = string.Concat(title.Trim().Select(character =>
            Path.GetInvalidFileNameChars().Contains(character) ? '-' : character));
        return safe.EndsWith(".budget", StringComparison.OrdinalIgnoreCase)
            ? safe[..^7]
            : safe;
    }
}
