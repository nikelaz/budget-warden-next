using Bw_core;
using BudgetWarden_Windows.ViewModels;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using CoreApi = Bw_core.Bw_core;

namespace BudgetWarden_Windows.Views;

public sealed partial class BudgetView : UserControl
{
    private bool _isPopulatingInspector;
    private CategoryListItemViewModel? _selectedCategoryListItem;
    private readonly HashSet<FrameworkElement> _categoryGroupHeaders = [];
    private bool _categoryGroupHeaderLayoutPending;
    private bool _categoryGroupHeaderLayoutQueued;

    public AppViewModel Vm => App.ViewModel;

    public BudgetView()
    {
        InitializeComponent();
    }

    private void BudgetView_Loaded(object sender, RoutedEventArgs e) =>
        QueueCategoryGroupHeaderLayout();

    private void BudgetInspectorToggle_Click(object sender, RoutedEventArgs e) =>
        BudgetInspectorSplitView.IsPaneOpen = BudgetInspectorToggle.IsChecked == true;

    private void BudgetInspectorSelector_Loaded(object sender, RoutedEventArgs e)
    {
        BudgetInspectorSelector.SelectedIndex = Vm.SelectedCategory is null ? 0 : 1;
        PopulateCategoryInspector(Vm.SelectedCategory);
        UpdateBudgetInspectorContent();
    }

    private void CategoryList_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        CategoryListItemViewModel? selectedItem =
            CategoryList.SelectedItem as CategoryListItemViewModel;
        if (selectedItem is { IsFooter: true })
        {
            CategoryList.SelectedItem = _selectedCategoryListItem;
            return;
        }

        _selectedCategoryListItem = selectedItem;
        CategoryRowViewModel? selected = selectedItem?.Category;
        Vm.SelectedCategory = selected;
        PopulateCategoryInspector(selected);
        BudgetInspectorSelector.SelectedIndex = selected is null ? 0 : 1;
        if (selected is not null)
        {
            BudgetInspectorToggle.IsChecked = true;
            BudgetInspectorSplitView.IsPaneOpen = true;
        }
    }

    private void CategoryGroupHeader_Loaded(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement header)
        {
            _categoryGroupHeaders.Add(header);
            QueueCategoryGroupHeaderLayout();
        }
    }

    private void CategoryGroupHeader_Unloaded(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement header)
        {
            _categoryGroupHeaders.Remove(header);
        }
    }

    private void CategoryList_SizeChanged(object sender, SizeChangedEventArgs e) =>
        QueueCategoryGroupHeaderLayout();

    private void CategoryList_LayoutUpdated(object? sender, object e)
    {
        if (_categoryGroupHeaderLayoutPending)
        {
            QueueCategoryGroupHeaderLayout();
        }
    }

    private void QueueCategoryGroupHeaderLayout()
    {
        _categoryGroupHeaderLayoutPending = true;
        if (_categoryGroupHeaderLayoutQueued)
        {
            return;
        }

        _categoryGroupHeaderLayoutQueued = DispatcherQueue.TryEnqueue(() =>
        {
            _categoryGroupHeaderLayoutQueued = false;
            UpdateCategoryGroupHeaderLayout();
        });
    }

    private void UpdateCategoryGroupHeaderLayout()
    {
        FrameworkElement? row = FindCategoryDataRow(CategoryList);
        if (row is null || row.ActualWidth <= 0)
        {
            return;
        }

        double rowX = row
            .TransformToVisual(CategoryList)
            .TransformPoint(default)
            .X;
        foreach (FrameworkElement header in _categoryGroupHeaders)
        {
            if (header.XamlRoot is null)
            {
                continue;
            }

            header.Width = row.ActualWidth;
            double headerX = header
                .TransformToVisual(CategoryList)
                .TransformPoint(default)
                .X;
            Thickness margin = header.Margin;
            header.Margin = new Thickness(
                margin.Left + rowX - headerX,
                margin.Top,
                margin.Right,
                margin.Bottom);
        }

        _categoryGroupHeaderLayoutPending = false;
    }

    private static FrameworkElement? FindCategoryDataRow(DependencyObject parent)
    {
        int childCount = VisualTreeHelper.GetChildrenCount(parent);
        for (int index = 0; index < childCount; index++)
        {
            DependencyObject child = VisualTreeHelper.GetChild(parent, index);
            if (child is FrameworkElement { Tag: "CategoryDataRow" } row
                && row.Visibility == Visibility.Visible)
            {
                return row;
            }

            FrameworkElement? descendant = FindCategoryDataRow(child);
            if (descendant is not null)
            {
                return descendant;
            }
        }

        return null;
    }

    private void BudgetInspectorSelector_SelectionChanged(
        object sender,
        SelectionChangedEventArgs args) =>
        UpdateBudgetInspectorContent();

    private void UpdateBudgetInspectorContent()
    {
        if (BudgetAtAGlanceContent is null || CategoryInspectorContent is null)
        {
            return;
        }

        bool showInspector =
            BudgetInspectorSelector.SelectedIndex == 1 && Vm.SelectedCategory is not null;
        if (!showInspector && BudgetInspectorSelector.SelectedIndex == 1)
        {
            BudgetInspectorSelector.SelectedIndex = 0;
            return;
        }

        BudgetAtAGlanceContent.Visibility =
            showInspector ? Visibility.Collapsed : Visibility.Visible;
        CategoryInspectorContent.Visibility =
            showInspector ? Visibility.Visible : Visibility.Collapsed;
    }

    private void PopulateCategoryInspector(CategoryRowViewModel? category)
    {
        _isPopulatingInspector = true;
        try
        {
            CategoryInspectorTitleBox.Text = category?.Title ?? string.Empty;
            CategoryInspectorTypeBox.SelectedItem = category is null
                ? null
                : Vm.CategoryTypes.First(item => item.Value == category.Category.CategoryType);
            CategoryInspectorPlannedBox.Text = category is null
                ? string.Empty
                : CoreApi.FormatMoneyInput(category.Category.AmountPlanned);
            CategoryInspectorAccumulatedBox.Text = category is null
                ? string.Empty
                : CoreApi.FormatMoneyInput(category.Category.AmountAccumulated);
            UpdateCategoryAccumulatedField(category?.Category.CategoryType);
            CategoryInspectorApplyButton.IsEnabled = false;
        }
        finally
        {
            _isPopulatingInspector = false;
        }
    }

    private void CategoryInspectorField_Changed(object sender, TextChangedEventArgs e) =>
        UpdateCategoryApplyState();

    private void CategoryInspectorField_Changed(object sender, SelectionChangedEventArgs e)
    {
        UpdateCategoryAccumulatedField(
            (CategoryInspectorTypeBox.SelectedItem as CategoryTypeOption)?.Value);
        UpdateCategoryApplyState();
    }

    private void UpdateCategoryAccumulatedField(BwCategoryType? categoryType)
    {
        bool show = categoryType is BwCategoryType.Savings or BwCategoryType.Debt;
        CategoryInspectorAccumulatedBox.Visibility =
            show ? Visibility.Visible : Visibility.Collapsed;
        CategoryInspectorAccumulatedBox.Header =
            categoryType == BwCategoryType.Debt ? "Leftover debt" : "Accumulated";
    }

    private void UpdateCategoryApplyState()
    {
        if (_isPopulatingInspector)
        {
            return;
        }

        CategoryRowViewModel? category = Vm.SelectedCategory;
        if (category is null
            || CategoryInspectorTypeBox.SelectedItem is not CategoryTypeOption type
            || string.IsNullOrWhiteSpace(CategoryInspectorTitleBox.Text)
            || !BudgetDialogs.IsMoney(CategoryInspectorPlannedBox.Text, true)
            || (type.HasAccumulated
                && !BudgetDialogs.IsMoney(CategoryInspectorAccumulatedBox.Text, true)))
        {
            CategoryInspectorApplyButton.IsEnabled = false;
            return;
        }

        string title = CategoryInspectorTitleBox.Text.Trim();
        BwMoneyAmount plannedAmount =
            CoreApi.ParseMoneyAmount(CategoryInspectorPlannedBox.Text, 0)!.Value;
        BwMoneyAmount accumulatedAmount = type.HasAccumulated
            ? CoreApi.ParseMoneyAmount(CategoryInspectorAccumulatedBox.Text, 0)!.Value
            : new BwMoneyAmount(0);
        CategoryInspectorApplyButton.IsEnabled =
            title != category.Category.Title
            || type.Value != category.Category.CategoryType
            || plannedAmount != category.Category.AmountPlanned
            || accumulatedAmount != category.Category.AmountAccumulated;
    }

    private async void ApplyCategoryInspector_Click(object sender, RoutedEventArgs e)
    {
        CategoryRowViewModel? category = Vm.SelectedCategory;
        if (category is null
            || CategoryInspectorTypeBox.SelectedItem is not CategoryTypeOption type
            || !CategoryInspectorApplyButton.IsEnabled)
        {
            return;
        }

        Exception? error = await Vm.RunAsync(
            () => Vm.UpdateCategoryAsync(
                category.Id,
                CategoryInspectorTitleBox.Text,
                CategoryInspectorPlannedBox.Text,
                CategoryInspectorAccumulatedBox.Text,
                type.Value),
            "Category saved.");
        if (error is null)
        {
            CategoryInspectorApplyButton.IsEnabled = false;
        }
    }

    private async void NewBudget_Click(object sender, RoutedEventArgs e) =>
        await CreateBudgetAsync();

    private async void OpenRecent_Click(object sender, RoutedEventArgs e) =>
        await BudgetDialogs.OpenRecentAsync(this, Vm, sender, BudgetSwitcherButton.Flyout);

    private async void NewCategory_Click(object sender, RoutedEventArgs e) =>
        await CreateCategoryAsync();

    private async void NewCategoryForGroup_Click(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { DataContext: CategoryListItemViewModel item })
        {
            await BudgetDialogs.ShowCategoryAsync(this, Vm, initialType: item.CategoryType);
        }
    }

    private async void NewTransaction_Click(object sender, RoutedEventArgs e) =>
        await CreateTransactionAsync();

    private async void DeleteCategory_Click(object sender, RoutedEventArgs e)
    {
        CategoryRowViewModel? category = Vm.SelectedCategory;
        if (category is null
            || !await BudgetDialogs.ConfirmAsync(
                this,
                $"Delete {category.Title}?",
                "This removes the category and all of its transactions.",
                "Delete category"))
        {
            return;
        }

        Vm.SelectedCategory = null;
        await Vm.RunAsync(() => Vm.DeleteCategoryAsync(category.Id), "Category deleted.");
    }

    public Task CreateBudgetAsync() =>
        BudgetDialogs.CreateBudgetAsync(this, Vm, BudgetSwitcherButton.Flyout);

    public Task CreateCategoryAsync() =>
        BudgetDialogs.ShowCategoryAsync(this, Vm);

    public Task CreateTransactionAsync() =>
        BudgetDialogs.ShowTransactionAsync(this, Vm);
}

public sealed class CategoryListItemContainerStyleSelector : StyleSelector
{
    public Style? CategoryStyle { get; set; }
    public Style? FooterStyle { get; set; }

    protected override Style? SelectStyleCore(object item, DependencyObject container) =>
        item is CategoryListItemViewModel { IsFooter: true }
            ? FooterStyle
            : CategoryStyle;
}
