using BudgetWarden_Windows.ViewModels;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace BudgetWarden_Windows.Views;

public sealed partial class ReportingView : UserControl
{
    public static readonly DependencyProperty DataProperty = DependencyProperty.Register(
        nameof(Data),
        typeof(ReportingPresentation),
        typeof(ReportingView),
        new PropertyMetadata(ReportingPresentation.Empty, OnDataChanged));

    public ReportingPresentation Data
    {
        get => GetValue(DataProperty) as ReportingPresentation ?? ReportingPresentation.Empty;
        set => SetValue(DataProperty, value ?? ReportingPresentation.Empty);
    }

    public ReportingView()
    {
        InitializeComponent();
        Loaded += (_, _) =>
        {
            if (AmountSelector.SelectedIndex < 0)
            {
                AmountSelector.SelectedIndex = 0;
            }
            RefreshCharts();
        };
    }

    private static void OnDataChanged(DependencyObject sender, DependencyPropertyChangedEventArgs args) =>
        ((ReportingView)sender).RefreshCharts();

    private void AmountSelector_SelectionChanged(object sender, SelectionChangedEventArgs e) => RefreshCharts();

    private void RefreshCharts()
    {
        if (ChartItems is null || AmountSelector is null)
        {
            return;
        }

        ChartItems.ItemsSource =
            AmountSelector.SelectedIndex == 1 ? Data.ActualCharts : Data.PlannedCharts;
    }
}
