using System.Globalization;
using System.Collections.ObjectModel;
using Bw_core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;
using Windows.UI;

namespace BudgetWarden_Windows.ViewModels;

public enum ReportingMetricTone
{
    Normal,
    Positive,
    Negative,
}

public enum ReportingChartKind
{
    Comparison,
    Donut,
}

public sealed partial record ReportingMetricViewModel(
    string Title,
    string Value,
    ReportingMetricTone Tone);

public readonly record struct ReportingChartColor(Color Light, Color Dark);

public sealed partial record ReportingChartSegmentViewModel(
    string Title,
    string RowTitle,
    long Amount,
    string FormattedAmount,
    string Percent,
    ReportingChartColor ChartColor)
{
    public SolidColorBrush Brush { get; } = new(ChartColor.Light);
    public Color ResolvedColor => Brush.Color;

    public void ApplyTheme(ElementTheme theme) =>
        Brush.Color = theme == ElementTheme.Dark ? ChartColor.Dark : ChartColor.Light;
}

public sealed partial record ReportingChartViewModel(
    string Title,
    string EmptyTitle,
    ReportingChartKind Kind,
    ObservableCollection<ReportingChartSegmentViewModel> Segments,
    ObservableCollection<string> SummaryLines)
{
    public bool HasData => Segments.Count > 0 && Segments.Any(segment => segment.Amount > 0);

    public ObservableCollection<ReportingChartSegmentViewModel> LegendSegments { get; } =
        Kind == ReportingChartKind.Donut
            ? Segments
            : new ObservableCollection<ReportingChartSegmentViewModel>(
                Segments
                    .GroupBy(segment => segment.Title)
                    .Select(group =>
                    {
                        ReportingChartSegmentViewModel segment = group.First();
                        return segment with { FormattedAmount = string.Empty };
                    }));
}

public sealed partial class ReportingPresentation
{
    // Light Palette B / Dark Palette B. Keep the pairs in the same order so a
    // category retains its identity when the app theme changes.
    private static readonly ReportingChartColor[] Palette =
    [
        ChartColor(0x25, 0x63, 0xEB, 0x60, 0xA5, 0xFA), // Blue
        ChartColor(0xF9, 0x73, 0x16, 0xFB, 0x71, 0x85), // Orange / pink
        ChartColor(0x06, 0xB6, 0xD4, 0x22, 0xD3, 0xEE), // Cyan
        ChartColor(0xEA, 0xB3, 0x08, 0xFB, 0xBF, 0x24), // Yellow
        ChartColor(0xA8, 0x55, 0xF7, 0xC0, 0x84, 0xFC), // Purple
        ChartColor(0x84, 0xCC, 0x16, 0xA3, 0xE6, 0x35), // Green
    ];

    private static readonly ReportingChartColor IncomeColor = Palette[0];
    private static readonly ReportingChartColor ExpenseColor = Palette[1];
    private static readonly ReportingChartColor SavingsColor = Palette[2];
    private static readonly ReportingChartColor DebtColor = Palette[3];

    public static ReportingPresentation Empty { get; } = new([], [], []);

    public ObservableCollection<ReportingMetricViewModel> Metrics { get; }
    public ObservableCollection<ReportingChartViewModel> PlannedCharts { get; }
    public ObservableCollection<ReportingChartViewModel> ActualCharts { get; }

    private ReportingPresentation(
        ObservableCollection<ReportingMetricViewModel> metrics,
        ObservableCollection<ReportingChartViewModel> plannedCharts,
        ObservableCollection<ReportingChartViewModel> actualCharts)
    {
        Metrics = metrics;
        PlannedCharts = plannedCharts;
        ActualCharts = actualCharts;
    }

    public static ReportingPresentation From(
        BwReportingSummary report,
        Func<long, string> formatMoney)
    {
        long income = report.Totals.Income.Value;
        long plannedSpending = report.Totals.PlannedSpending.Value;
        long actualSpending = report.Totals.ActualSpending.Value;
        long savings = report.Totals.PlannedSavings.Value;
        long leftToBudget = report.Totals.LeftToBudget;

        ObservableCollection<ReportingMetricViewModel> metrics =
        [
            new("Income", formatMoney(income), ReportingMetricTone.Normal),
            new(
                "Planned Spending",
                formatMoney(plannedSpending),
                plannedSpending > income ? ReportingMetricTone.Negative : ReportingMetricTone.Normal),
            new(
                "Actual Spending",
                formatMoney(actualSpending),
                actualSpending > plannedSpending ? ReportingMetricTone.Negative : ReportingMetricTone.Positive),
            new("Savings", formatMoney(savings), ReportingMetricTone.Normal),
            new(
                "Left to Budget",
                formatMoney(leftToBudget),
                leftToBudget < 0 ? ReportingMetricTone.Negative : ReportingMetricTone.Normal),
        ];

        ReportingChartViewModel comparison = ComparisonChart(report, formatMoney);
        return new(
            metrics,
            ChartsForMode(report, BwReportingAmountMode.Planned, "Planned", comparison, formatMoney),
            ChartsForMode(report, BwReportingAmountMode.Actual, "Actual", comparison, formatMoney));
    }

    private static ObservableCollection<ReportingChartViewModel> ChartsForMode(
        BwReportingSummary report,
        BwReportingAmountMode mode,
        string modeTitle,
        ReportingChartViewModel comparison,
        Func<long, string> formatMoney) =>
    [
        comparison,
        DonutChart(
            $"{modeTitle} Allocation Breakdown",
            $"No {modeTitle.ToLowerInvariant()} allocation amounts yet",
            report.AllocationSegments
                .Where(segment => segment.AmountMode == mode)
                .Select(segment => (
                    TypeLabel(segment.CategoryType),
                    segment.Amount.Value,
                    TypeColor(segment.CategoryType))),
            formatMoney),
        CategoryChart("Income Breakdown", BwCategoryType.Income, report, mode, modeTitle, formatMoney),
        CategoryChart("Expenses Breakdown", BwCategoryType.Expenses, report, mode, modeTitle, formatMoney),
        CategoryChart("Savings Breakdown", BwCategoryType.Savings, report, mode, modeTitle, formatMoney),
        CategoryChart("Debt Breakdown", BwCategoryType.Debt, report, mode, modeTitle, formatMoney),
    ];

    private static ReportingChartViewModel ComparisonChart(
        BwReportingSummary report,
        Func<long, string> formatMoney)
    {
        ObservableCollection<ReportingChartSegmentViewModel> segments = new(
            report.ComparisonSegments
                .Select(segment => new ReportingChartSegmentViewModel(
                    ComponentLabel(segment.Component),
                    RowLabel(segment.Row),
                    segment.Amount.Value,
                    formatMoney(segment.Amount.Value),
                    string.Empty,
                    ComponentColor(segment.Component))));

        ObservableCollection<string> totals =
        [
            $"Income: {formatMoney(report.Totals.Income.Value)}",
            $"Planned: {formatMoney(report.Totals.PlannedAllocation.Value)}",
            $"Actual: {formatMoney(report.Totals.ActualAllocation.Value)}",
        ];
        return new(
            "Income vs Allocation",
            "No allocation amounts yet",
            ReportingChartKind.Comparison,
            segments,
            totals);
    }

    private static ReportingChartViewModel CategoryChart(
        string title,
        BwCategoryType type,
        BwReportingSummary report,
        BwReportingAmountMode mode,
        string modeTitle,
        Func<long, string> formatMoney)
    {
        var source = report.CategorySegments
            .Where(segment => segment.AmountMode == mode && segment.CategoryType == type)
            .Select((segment, index) => (segment.Title, segment.Amount.Value, Palette[index % Palette.Length]));
        return DonutChart(
            title,
            $"No {modeTitle.ToLowerInvariant()} {TypeLabel(type).ToLowerInvariant()} amounts yet",
            source,
            formatMoney);
    }

    private static ReportingChartViewModel DonutChart(
        string title,
        string emptyTitle,
        IEnumerable<(string Title, long Amount, ReportingChartColor Color)> source,
        Func<long, string> formatMoney)
    {
        (string Title, long Amount, ReportingChartColor Color)[] values =
            source.Where(item => item.Amount > 0).ToArray();
        long total = values.Aggregate(0L, (sum, item) => checked(sum + item.Amount));
        ObservableCollection<ReportingChartSegmentViewModel> segments = new(
            values.Select(item => new ReportingChartSegmentViewModel(
                item.Title,
                string.Empty,
                item.Amount,
                formatMoney(item.Amount),
                total == 0
                    ? "0%"
                    : ((double)item.Amount / total).ToString("0.#%", CultureInfo.CurrentCulture),
                item.Color)));
        return new(title, emptyTitle, ReportingChartKind.Donut, segments, []);
    }

    private static string TypeLabel(BwCategoryType type) => type switch
    {
        BwCategoryType.Income => "Income",
        BwCategoryType.Expenses => "Expenses",
        BwCategoryType.Savings => "Savings",
        BwCategoryType.Debt => "Debt",
        _ => type.ToString(),
    };

    private static ReportingChartColor TypeColor(BwCategoryType type) => type switch
    {
        BwCategoryType.Expenses => ExpenseColor,
        BwCategoryType.Savings => SavingsColor,
        BwCategoryType.Debt => DebtColor,
        _ => IncomeColor,
    };

    private static string RowLabel(BwReportingComparisonRow row) => row switch
    {
        BwReportingComparisonRow.Income => "Income",
        BwReportingComparisonRow.Planned => "Planned Allocation",
        BwReportingComparisonRow.Actual => "Actual Allocation",
        _ => row.ToString(),
    };

    private static string ComponentLabel(BwReportingComponent component) => component switch
    {
        BwReportingComponent.Income => "Income",
        BwReportingComponent.Expenses => "Expenses",
        BwReportingComponent.Savings => "Savings",
        BwReportingComponent.Debt => "Debt",
        _ => component.ToString(),
    };

    private static ReportingChartColor ComponentColor(BwReportingComponent component) => component switch
    {
        BwReportingComponent.Income => IncomeColor,
        BwReportingComponent.Expenses => ExpenseColor,
        BwReportingComponent.Savings => SavingsColor,
        BwReportingComponent.Debt => DebtColor,
        _ => IncomeColor,
    };

    private static ReportingChartColor ChartColor(
        byte lightRed,
        byte lightGreen,
        byte lightBlue,
        byte darkRed,
        byte darkGreen,
        byte darkBlue) =>
        new(
            Color.FromArgb(255, lightRed, lightGreen, lightBlue),
            Color.FromArgb(255, darkRed, darkGreen, darkBlue));
}
