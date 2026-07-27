using System.Numerics;
using BudgetWarden_Windows.ViewModels;
using Microsoft.Graphics.Canvas;
using Microsoft.Graphics.Canvas.Geometry;
using Microsoft.Graphics.Canvas.Text;
using Microsoft.Graphics.Canvas.UI.Xaml;
using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.Foundation;
using Windows.UI;

namespace BudgetWarden_Windows.Views;

public sealed partial class ReportingChartCard : UserControl
{
    private static readonly string[] ComparisonRows = ["Income", "Planned Allocation", "Actual Allocation"];

    public static readonly DependencyProperty ModelProperty = DependencyProperty.Register(
        nameof(Model),
        typeof(ReportingChartViewModel),
        typeof(ReportingChartCard),
        new PropertyMetadata(null, OnModelChanged));

    public ReportingChartViewModel? Model
    {
        get => (ReportingChartViewModel?)GetValue(ModelProperty);
        set => SetValue(ModelProperty, value);
    }

    public ReportingChartCard()
    {
        InitializeComponent();
        ActualThemeChanged += (_, _) =>
        {
            ApplyChartTheme();
            ChartCanvas.Invalidate();
        };
    }

    private static void OnModelChanged(DependencyObject sender, DependencyPropertyChangedEventArgs args) =>
        ((ReportingChartCard)sender).Refresh();

    private void Refresh()
    {
        if (ChartCanvas is null || EmptyText is null)
        {
            return;
        }

        bool hasData = Model?.HasData == true;
        TitleText.Text = Model?.Title ?? string.Empty;
        ChartCanvas.Visibility = hasData ? Visibility.Visible : Visibility.Collapsed;
        EmptyText.Visibility = hasData ? Visibility.Collapsed : Visibility.Visible;
        EmptyText.Text = Model?.EmptyTitle ?? string.Empty;
        LegendItems.ItemsSource = hasData ? Model?.LegendSegments : null;
        LegendItems.Visibility = hasData ? Visibility.Visible : Visibility.Collapsed;
        SummaryItems.ItemsSource = hasData ? Model?.SummaryLines : null;
        bool hasSummary = hasData && Model?.SummaryLines.Count > 0;
        SummaryItems.Visibility = hasSummary
            ? Visibility.Visible
            : Visibility.Collapsed;
        Grid.SetColumnSpan(LegendItems, hasSummary ? 1 : 2);
        AutomationProperties.SetName(
            ChartCanvas,
            Model is null ? "Reporting chart" : $"{Model.Title}. {string.Join(". ", Model.SummaryLines)}");
        ApplyChartTheme();
        ChartCanvas.Invalidate();
    }

    private void ApplyChartTheme()
    {
        if (Model is null)
        {
            return;
        }

        foreach (ReportingChartSegmentViewModel segment in Model.Segments)
        {
            segment.ApplyTheme(ActualTheme);
        }
    }

    private void ChartCanvas_Draw(CanvasControl sender, CanvasDrawEventArgs args)
    {
        if (Model?.HasData != true)
        {
            return;
        }

        if (Model.Kind == ReportingChartKind.Comparison)
        {
            DrawComparison(
                args.DrawingSession,
                (float)sender.ActualWidth,
                (float)sender.ActualHeight,
                sender.Dpi / 96);
        }
        else
        {
            DrawDonut(args.DrawingSession, (float)sender.ActualWidth, (float)sender.ActualHeight);
        }
    }

    private void DrawComparison(CanvasDrawingSession drawing, float width, float height, float rasterizationScale)
    {
        const float labelWidth = 104;
        const float rightPadding = 8;
        const float barHeight = 22;
        const float segmentGap = 2;
        const float cornerRadius = 3;
        float barX = SnapToPixel(labelWidth, rasterizationScale);
        float chartRight = SnapToPixel(width - rightPadding, rasterizationScale);
        float chartWidth = Math.Max(1, chartRight - barX);
        long maximum = Math.Max(1, Model!.Segments
            .GroupBy(segment => segment.RowTitle)
            .Select(row => row.Sum(segment => segment.Amount))
            .DefaultIfEmpty(1)
            .Max());
        Color textColor = ThemeColor("TextFillColorSecondaryBrush", Colors.Gray);
        Color trackColor = ThemeColor("ControlFillColorSecondaryBrush", Color.FromArgb(60, 128, 128, 128));
        using CanvasTextFormat format = new() { FontSize = 11, VerticalAlignment = CanvasVerticalAlignment.Center };

        for (int index = 0; index < ComparisonRows.Length; index++)
        {
            string row = ComparisonRows[index];
            float barY = SnapToPixel(14 + index * 47, rasterizationScale);
            float snappedBarHeight =
                SnapToPixel(barY + barHeight, rasterizationScale) - barY;
            drawing.DrawText(
                row,
                new Rect(0, barY, barX, snappedBarHeight),
                textColor,
                format);
            drawing.FillRoundedRectangle(
                barX,
                barY,
                chartWidth,
                snappedBarHeight,
                cornerRadius,
                cornerRadius,
                trackColor);

            ReportingChartSegmentViewModel[] segments = Model.Segments
                .Where(item => item.RowTitle == row && item.Amount > 0)
                .ToArray();
            long rowTotal = segments.Sum(segment => segment.Amount);
            if (rowTotal == 0)
            {
                continue;
            }

            float filledRight = SnapToPixel(
                barX + chartWidth * rowTotal / maximum,
                rasterizationScale);
            float filledWidth = filledRight - barX;
            float gap = segments.Length > 1
                ? Math.Min(
                    SnapToPixel(segmentGap, rasterizationScale),
                    filledWidth / (segments.Length * 2))
                : 0;
            float segmentsWidth = Math.Max(0, filledWidth - gap * (segments.Length - 1));
            float x = barX;
            long cumulativeAmount = 0;

            using CanvasGeometry clip = CanvasGeometry.CreateRoundedRectangle(
                drawing.Device,
                barX,
                barY,
                filledWidth,
                snappedBarHeight,
                cornerRadius,
                cornerRadius);
            using CanvasActiveLayer layer = drawing.CreateLayer(1, clip);
            for (int segmentIndex = 0; segmentIndex < segments.Length; segmentIndex++)
            {
                ReportingChartSegmentViewModel segment = segments[segmentIndex];
                cumulativeAmount += segment.Amount;
                float segmentRight = segmentIndex == segments.Length - 1
                    ? filledRight
                    : SnapToPixel(
                        barX
                            + gap * segmentIndex
                            + segmentsWidth * cumulativeAmount / rowTotal,
                        rasterizationScale);
                float segmentWidth = Math.Max(0, segmentRight - x);
                if (segmentWidth > 0)
                {
                    drawing.FillRectangle(
                        x,
                        barY,
                        segmentWidth,
                        snappedBarHeight,
                        segment.ResolvedColor);
                }
                x = SnapToPixel(segmentRight + gap, rasterizationScale);
            }
        }
    }

    private static float SnapToPixel(float value, float rasterizationScale) =>
        rasterizationScale > 0
            ? MathF.Round(value * rasterizationScale) / rasterizationScale
            : value;

    private void DrawDonut(CanvasDrawingSession drawing, float width, float height)
    {
        Vector2 center = new(width / 2, height / 2);
        float radius = Math.Max(10, Math.Min(width, height) * 0.34f);
        float strokeWidth = Math.Max(12, radius * 0.42f);
        long total = Model!.Segments.Sum(segment => segment.Amount);
        float start = -MathF.PI / 2;

        foreach (ReportingChartSegmentViewModel segment in Model.Segments)
        {
            float sweep = MathF.Tau * segment.Amount / total;
            Vector2 startPoint = center + new Vector2(MathF.Cos(start), MathF.Sin(start)) * radius;
            using CanvasPathBuilder path = new(drawing.Device);
            path.BeginFigure(startPoint);
            path.AddArc(center, radius, radius, start, sweep);
            path.EndFigure(CanvasFigureLoop.Open);
            using CanvasGeometry geometry = CanvasGeometry.CreatePath(path);
            drawing.DrawGeometry(geometry, segment.ResolvedColor, strokeWidth);
            start += sweep;
        }

        if (Model.Segments.Count > 1)
        {
            const float separatorWidth = 2;
            float innerRadius = radius - strokeWidth / 2 - separatorWidth;
            float outerRadius = radius + strokeWidth / 2 + separatorWidth;
            float boundary = -MathF.PI / 2;

            drawing.Blend = CanvasBlend.Copy;
            foreach (ReportingChartSegmentViewModel segment in Model.Segments)
            {
                Vector2 direction = new(MathF.Cos(boundary), MathF.Sin(boundary));
                drawing.DrawLine(
                    center + direction * innerRadius,
                    center + direction * outerRadius,
                    Colors.Transparent,
                    separatorWidth);
                boundary += MathF.Tau * segment.Amount / total;
            }
            drawing.Blend = CanvasBlend.SourceOver;
        }
    }

    private Color ThemeColor(string key, Color fallback) =>
        Application.Current.Resources.TryGetValue(key, out object value) && value is SolidColorBrush brush
            ? brush.Color
            : fallback;
}
