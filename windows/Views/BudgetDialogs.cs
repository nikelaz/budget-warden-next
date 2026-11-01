using System.Globalization;
using System.Collections.ObjectModel;
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
            ItemsSource = new ObservableCollection<string>(
                templates.Select(template => template.DisplayName)),
            SelectedIndex = 0,
        };
        AutomationProperties.SetAutomationId(templateBox, "BudgetTemplateComboBox");
        AutomationProperties.SetName(templateBox, "Budget template");
        TextBlock templateDescription = new()
        {
            Text = templates[0].Description,
            TextWrapping = TextWrapping.Wrap,
            Style = Application.Current.Resources["BodyTextBlockStyle"] as Style,
        };
        StackPanel form = CreateForm(("Title", titleBox), ("Template", templateBox));
        form.Children.Add(templateDescription);
        CheckBox googleDriveBox = new()
        {
            Content = "Save to Google Drive",
            Visibility = ViewVisibility.When(viewModel.CanCreateInGoogleDrive),
        };
        AutomationProperties.SetAutomationId(googleDriveBox, "SaveToGoogleDriveCheckBox");
        form.Children.Add(googleDriveBox);
        templateBox.SelectionChanged += (_, _) =>
        {
            if (templateBox.SelectedIndex >= 0)
            {
                templateDescription.Text = templates[templateBox.SelectedIndex].Description;
            }
        };

        ContentDialog dialog = CreateDialog(
            owner,
            "New budget",
            form,
            "Create");
        dialog.IsPrimaryButtonEnabled = true;
        if (await dialog.ShowAsync() != ContentDialogResult.Primary
            || templateBox.SelectedIndex < 0)
        {
            return;
        }
        BudgetTemplate template = templates[templateBox.SelectedIndex];

        if (googleDriveBox.IsChecked == true && viewModel.CanCreateInGoogleDrive)
        {
            await RunWithErrorDialogAsync(
                owner,
                viewModel,
                () => viewModel.CreateCloudBudgetAsync(titleBox.Text, template),
                "Budget created in Google Drive.");
            return;
        }

        var picker = new FileSavePicker(App.WindowId)
        {
            SuggestedStartLocation = PickerLocationId.DocumentsLibrary,
            SuggestedFileName = SafeFileName(titleBox.Text),
        };
        picker.FileTypeChoices.Add(
            "Budget Warden budget",
            new ObservableCollection<string> { ".budget" });
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

    public static Task OpenCloudBudgetAsync(
        FrameworkElement owner,
        AppViewModel viewModel,
        CloudBudgetItem budget) =>
        RunWithErrorDialogAsync(
            owner,
            viewModel,
            () => viewModel.OpenCloudBudgetAsync(budget),
            "Budget opened.");

    /// <summary>Invites people to a Google Drive budget and manages who has access.</summary>
    public static async Task ShareCloudBudgetAsync(
        FrameworkElement owner,
        AppViewModel viewModel,
        CloudBudgetItem budget)
    {
        TextBox emailBox = CreateTextBox("name@example.com", "ShareEmailBox");
        emailBox.InputScope = new Microsoft.UI.Xaml.Input.InputScope
        {
            Names = { new Microsoft.UI.Xaml.Input.InputScopeName(Microsoft.UI.Xaml.Input.InputScopeNameValue.EmailSmtpAddress) },
        };
        ComboBox roleBox = new()
        {
            ItemsSource = new ObservableCollection<string> { "Can edit", "Can view" },
            SelectedIndex = 0,
        };
        AutomationProperties.SetName(roleBox, "Permission");
        TextBox messageBox = CreateTextBox("Optional message", "ShareMessageBox");
        TextBlock status = new()
        {
            TextWrapping = TextWrapping.Wrap,
            Foreground = Application.Current.Resources["SystemFillColorCriticalBrush"] as Microsoft.UI.Xaml.Media.Brush,
        };
        StackPanel people = new() { Spacing = 6 };

        StackPanel form = budget.CanShare
            ? CreateForm(("Email address", emailBox), ("Permission", roleBox), ("Message", messageBox))
            : new StackPanel { Spacing = 12, MinWidth = 420 };
        if (budget.CanShare)
        {
            form.Children.Add(new TextBlock
            {
                Text = "They receive an email from Google, and Budget Warden lists the budget for them under budgets shared with them.",
                TextWrapping = TextWrapping.Wrap,
                Style = Application.Current.Resources["CaptionTextBlockStyle"] as Style,
            });
        }
        form.Children.Add(status);
        form.Children.Add(new TextBlock
        {
            Text = "People with access",
            Style = Application.Current.Resources["BodyStrongTextBlockStyle"] as Style,
        });
        form.Children.Add(people);

        async Task ReloadAsync()
        {
            people.Children.Clear();
            try
            {
                foreach (BwCloudShare share in await viewModel.ListSharesAsync(budget))
                {
                    people.Children.Add(ShareRow(share));
                }
            }
            catch (BoltException error)
            {
                status.Text = AppViewModel.CloudMessage(error);
            }
        }

        UIElement ShareRow(BwCloudShare share)
        {
            string role = share.Role switch
            {
                BwCloudShareRole.Owner => "Owner",
                BwCloudShareRole.Writer => "Can edit",
                BwCloudShareRole.Commenter => "Can comment",
                _ => "Can view",
            };
            Grid row = new() { ColumnSpacing = 8 };
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            row.Children.Add(new TextBlock
            {
                Text = $"{share.DisplayName ?? share.Email ?? share.Kind} · {role}",
                TextTrimming = TextTrimming.CharacterEllipsis,
                VerticalAlignment = VerticalAlignment.Center,
            });
            if (budget.CanShare && share.Role != BwCloudShareRole.Owner)
            {
                Button remove = new() { Content = "Remove" };
                AutomationProperties.SetName(remove, $"Remove access for {share.Email ?? share.DisplayName}");
                remove.Click += async (_, _) =>
                {
                    remove.IsEnabled = false;
                    try
                    {
                        await viewModel.RemoveShareAsync(budget, share);
                    }
                    catch (BoltException error)
                    {
                        status.Text = AppViewModel.CloudMessage(error);
                    }
                    await ReloadAsync();
                };
                Grid.SetColumn(remove, 1);
                row.Children.Add(remove);
            }
            return row;
        }

        ContentDialog dialog = CreateDialog(owner, $"Share “{budget.Title}”", new ScrollViewer { Content = form }, "Send invite");
        dialog.CloseButtonText = "Done";
        dialog.IsPrimaryButtonEnabled = false;
        if (!budget.CanShare)
        {
            dialog.PrimaryButtonText = string.Empty;
        }
        emailBox.TextChanged += (_, _) => dialog.IsPrimaryButtonEnabled = emailBox.Text.Contains('@');
        dialog.PrimaryButtonClick += async (_, args) =>
        {
            // Keep the dialog open to show the updated list.
            args.Cancel = true;
            ContentDialogButtonClickDeferral deferral = args.GetDeferral();
            dialog.IsPrimaryButtonEnabled = false;
            try
            {
                await viewModel.ShareCloudBudgetAsync(budget, emailBox.Text, roleBox.SelectedIndex == 0, messageBox.Text);
                emailBox.Text = string.Empty;
                messageBox.Text = string.Empty;
                status.Text = string.Empty;
                await ReloadAsync();
            }
            catch (BoltException error)
            {
                status.Text = AppViewModel.CloudMessage(error);
                dialog.IsPrimaryButtonEnabled = true;
            }
            finally
            {
                deferral.Complete();
            }
        };

        _ = ReloadAsync();
        await dialog.ShowAsync();
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
            ItemsSource = new ObservableCollection<string>(
                viewModel.CategoryTypes.Select(type => type.DisplayName)),
            SelectedIndex = 1,
        };
        AutomationProperties.SetAutomationId(typeBox, "CategoryTypeComboBox");
        AutomationProperties.SetName(typeBox, "Category type");

        if (category is not null)
        {
            titleBox.Text = category.Title;
            amountBox.Text = CoreApi.FormatMoneyInput(category.Category.AmountPlanned);
            accumulatedBox.Text = CoreApi.FormatMoneyInput(category.Category.AmountAccumulated);
            typeBox.SelectedIndex = IndexOfCategoryType(
                viewModel.CategoryTypes,
                category.Category.CategoryType);
        }
        else if (initialType is BwCategoryType categoryType)
        {
            typeBox.SelectedIndex = IndexOfCategoryType(viewModel.CategoryTypes, categoryType);
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
            CategoryTypeOption? selectedType = SelectedCategoryType(viewModel, typeBox);
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
            && SelectedCategoryType(viewModel, typeBox) is CategoryTypeOption selectedType
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
            || SelectedCategoryType(viewModel, typeBox) is not CategoryTypeOption type)
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
            ItemsSource = new ObservableCollection<string>(
                viewModel.Categories.Select(category => category.Title)),
            SelectedIndex = initialCategory is null
                ? 0
                : viewModel.Categories.IndexOf(initialCategory),
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
            categoryBox.SelectedIndex >= 0
            && !string.IsNullOrWhiteSpace(titleBox.Text)
            && IsMoney(amountBox.Text, false);
        titleBox.TextChanged += Validate;
        amountBox.TextChanged += Validate;
        categoryBox.SelectionChanged += Validate;
        Validate(null, new object());

        if (await dialog.ShowAsync() != ContentDialogResult.Primary
            || categoryBox.SelectedIndex < 0)
        {
            return;
        }
        CategoryRowViewModel category = viewModel.Categories[categoryBox.SelectedIndex];

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
            await ShowMessageAsync(owner, "Budget Warden", AppViewModel.CloudMessage(error));
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

    private static CategoryTypeOption? SelectedCategoryType(
        AppViewModel viewModel,
        ComboBox typeBox) =>
        typeBox.SelectedIndex >= 0 && typeBox.SelectedIndex < viewModel.CategoryTypes.Count
            ? viewModel.CategoryTypes[typeBox.SelectedIndex]
            : null;

    private static int IndexOfCategoryType(
        ObservableCollection<CategoryTypeOption> types,
        BwCategoryType categoryType) =>
        types
            .Select((type, index) => (type, index))
            .First(item => item.type.Value == categoryType)
            .index;
}
