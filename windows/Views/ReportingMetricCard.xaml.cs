using BudgetWarden_Windows.ViewModels;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace BudgetWarden_Windows.Views;

public sealed partial class ReportingMetricCard : UserControl
{
    public static readonly DependencyProperty ModelProperty = DependencyProperty.Register(
        nameof(Model),
        typeof(ReportingMetricViewModel),
        typeof(ReportingMetricCard),
        new PropertyMetadata(null, OnModelChanged));

    public ReportingMetricViewModel? Model
    {
        get => (ReportingMetricViewModel?)GetValue(ModelProperty);
        set => SetValue(ModelProperty, value);
    }

    public ReportingMetricCard()
    {
        InitializeComponent();
        ActualThemeChanged += (_, _) => UpdateTone();
    }

    private static void OnModelChanged(DependencyObject sender, DependencyPropertyChangedEventArgs args) =>
        ((ReportingMetricCard)sender).UpdateTone();

    private void UpdateTone()
    {
        if (ValueText is null)
        {
            return;
        }

        string? resource = Model?.Tone switch
        {
            ReportingMetricTone.Positive => "SystemFillColorSuccessBrush",
            ReportingMetricTone.Negative => "SystemFillColorCriticalBrush",
            _ => null,
        };
        if (resource is not null
            && Application.Current.Resources.TryGetValue(resource, out object value)
            && value is Brush brush)
        {
            ValueText.Foreground = brush;
        }
        else
        {
            ValueText.ClearValue(TextBlock.ForegroundProperty);
        }
    }
}
