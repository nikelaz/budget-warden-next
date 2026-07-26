using System.ComponentModel;
using Microsoft.UI.Input;
using Microsoft.UI;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using System.Runtime.InteropServices;
using BudgetWarden_Windows.ViewModels;
using Windows.Graphics;
using Rect = Windows.Foundation.Rect;

// To learn more about WinUI, the WinUI project structure,
// and more about our project templates, see: http://aka.ms/winui-project-info.

namespace BudgetWarden_Windows.Views;

/// <summary>
/// The application window. This hosts a Frame that displays pages. Add your
/// UI and logic to MainPage.xaml / MainPage.xaml.cs instead of here so you
/// can use Page features such as navigation events and the Loaded lifecycle.
/// </summary>
public sealed partial class MainWindow : Window
{
    [DllImport("user32.dll")]
    private static extern uint GetDpiForWindow(nint windowHandle);

    public MainWindow()
    {
        InitializeComponent();

        ExtendsContentIntoTitleBar = true;
        SetTitleBar(AppTitleBar);
        AppTitleBar.Loaded += AppTitleBar_Loaded;
        AppTitleBar.SizeChanged += AppTitleBar_SizeChanged;

        AppWindow.SetIcon(Path.Combine(AppContext.BaseDirectory, "Assets", "AppIcon.ico"));

        SizeInitialWindow();

        // Navigate the root frame to the main page on startup.
        RootFrame.Navigate(typeof(MainPage));
        if (RootFrame.Content is MainPage page)
        {
            page.Vm.PropertyChanged += AppViewModel_PropertyChanged;
        }
        UpdateEditMenuState();
        UpdateTransactionSearchState();
    }

    private void SizeInitialWindow()
    {
        const double targetWidthDips = 1920;
        const double targetHeightDips = 1080;
        const double workAreaMarginDips = 32;

        DisplayArea? displayArea =
            DisplayArea.GetFromWindowId(AppWindow.Id, DisplayAreaFallback.Nearest);
        if (displayArea is null)
        {
            return;
        }

        nint windowHandle = Win32Interop.GetWindowFromWindowId(AppWindow.Id);
        double scale = GetDpiForWindow(windowHandle) / 96.0;
        RectInt32 workArea = displayArea.WorkArea;
        int margin = (int)Math.Round(workAreaMarginDips * scale);
        int width = Math.Min(
            (int)Math.Round(targetWidthDips * scale),
            Math.Max(1, workArea.Width - (margin * 2)));
        int height = Math.Min(
            (int)Math.Round(targetHeightDips * scale),
            Math.Max(1, workArea.Height - (margin * 2)));
        int x = workArea.X + ((workArea.Width - width) / 2);
        int y = workArea.Y + ((workArea.Height - height) / 2);

        AppWindow.MoveAndResize(new RectInt32(x, y, width, height));
    }

    private MainPage? CurrentPage => RootFrame.Content as MainPage;

    private void AppViewModel_PropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(CurrentPage.Vm.HasBudget))
        {
            UpdateEditMenuState();
        }
        else if (e.PropertyName == nameof(CurrentPage.Vm.IsTransactionsPage))
        {
            UpdateTransactionSearchState();
        }
    }

    private void UpdateEditMenuState()
    {
        bool hasBudget = CurrentPage?.Vm.HasBudget == true;
        EditNewCategoryMenuItem.IsEnabled = hasBudget;
        EditNewTransactionMenuItem.IsEnabled = hasBudget;
    }

    private void UpdateTransactionSearchState()
    {
        bool isTransactionsPage = CurrentPage?.Vm.IsTransactionsPage == true;
        TransactionSearchBox.Visibility =
            isTransactionsPage ? Visibility.Visible : Visibility.Collapsed;

        if (isTransactionsPage
            && CurrentPage is MainPage page
            && TransactionSearchBox.Text != page.Vm.SearchText)
        {
            TransactionSearchBox.Text = page.Vm.SearchText;
        }

        QueueTitleBarPassthroughRegionUpdate();
    }

    private void AppTitleBar_Loaded(object sender, RoutedEventArgs e) =>
        QueueTitleBarPassthroughRegionUpdate();

    private void AppTitleBar_SizeChanged(object sender, SizeChangedEventArgs e) =>
        QueueTitleBarPassthroughRegionUpdate();

    private void QueueTitleBarPassthroughRegionUpdate() =>
        DispatcherQueue.TryEnqueue(SetTitleBarPassthroughRegions);

    private void SetTitleBarPassthroughRegions()
    {
        if (!ExtendsContentIntoTitleBar || AppTitleBar.XamlRoot is null)
        {
            return;
        }

        double scale = AppTitleBar.XamlRoot.RasterizationScale;
        List<RectInt32> regions = [GetPhysicalBounds(MainMenuBar, scale)];

        if (TransactionSearchBox.Visibility == Visibility.Visible)
        {
            regions.Add(GetPhysicalBounds(TransactionSearchBox, scale));
        }

        InputNonClientPointerSource
            .GetForWindowId(AppWindow.Id)
            .SetRegionRects(NonClientRegionKind.Passthrough, regions.ToArray());
    }

    private static RectInt32 GetPhysicalBounds(FrameworkElement element, double scale)
    {
        GeneralTransform transform = element.TransformToVisual(null);
        Rect bounds = transform.TransformBounds(
            new Rect(0, 0, element.ActualWidth, element.ActualHeight));

        return new RectInt32(
            (int)Math.Round(bounds.X * scale),
            (int)Math.Round(bounds.Y * scale),
            (int)Math.Round(bounds.Width * scale),
            (int)Math.Round(bounds.Height * scale));
    }

    private void TransactionSearchBox_TextChanged(
        AutoSuggestBox sender,
        AutoSuggestBoxTextChangedEventArgs e)
    {
        if (CurrentPage is MainPage page && page.Vm.IsTransactionsPage)
        {
            page.Vm.SearchText = sender.Text;
        }
    }

    private void NewBudget_Click(object sender, RoutedEventArgs e) =>
        CurrentPage?.NewBudgetFromMenu();

    private void OpenBudget_Click(object sender, RoutedEventArgs e) =>
        CurrentPage?.OpenBudgetFromMenu();

    private void NewCategory_Click(object sender, RoutedEventArgs e) =>
        CurrentPage?.NewCategoryFromMenu();

    private void NewTransaction_Click(object sender, RoutedEventArgs e) =>
        CurrentPage?.NewTransactionFromMenu();

    private void Exit_Click(object sender, RoutedEventArgs e) =>
        Close();
}
