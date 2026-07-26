using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Windows.Foundation;

namespace BudgetWarden_Windows.Views;

public sealed class ResponsiveGridPanel : Panel
{
    public static readonly DependencyProperty MinItemWidthProperty = DependencyProperty.Register(
        nameof(MinItemWidth),
        typeof(double),
        typeof(ResponsiveGridPanel),
        new PropertyMetadata(320d, OnLayoutPropertyChanged));

    public static readonly DependencyProperty HorizontalSpacingProperty = DependencyProperty.Register(
        nameof(HorizontalSpacing),
        typeof(double),
        typeof(ResponsiveGridPanel),
        new PropertyMetadata(0d, OnLayoutPropertyChanged));

    public static readonly DependencyProperty VerticalSpacingProperty = DependencyProperty.Register(
        nameof(VerticalSpacing),
        typeof(double),
        typeof(ResponsiveGridPanel),
        new PropertyMetadata(0d, OnLayoutPropertyChanged));

    public double MinItemWidth
    {
        get => (double)GetValue(MinItemWidthProperty);
        set => SetValue(MinItemWidthProperty, value);
    }

    public double HorizontalSpacing
    {
        get => (double)GetValue(HorizontalSpacingProperty);
        set => SetValue(HorizontalSpacingProperty, value);
    }

    public double VerticalSpacing
    {
        get => (double)GetValue(VerticalSpacingProperty);
        set => SetValue(VerticalSpacingProperty, value);
    }

    protected override Size MeasureOverride(Size availableSize)
    {
        if (Children.Count == 0)
        {
            return new Size(0, 0);
        }

        double width = double.IsFinite(availableSize.Width)
            ? Math.Max(0, availableSize.Width)
            : Math.Max(1, MinItemWidth);
        int columns = ColumnCount(width);
        double itemWidth = ItemWidth(width, columns);
        double totalHeight = 0;

        for (int rowStart = 0; rowStart < Children.Count; rowStart += columns)
        {
            double rowHeight = 0;
            int rowEnd = Math.Min(rowStart + columns, Children.Count);
            for (int index = rowStart; index < rowEnd; index++)
            {
                UIElement child = Children[index];
                child.Measure(new Size(itemWidth, double.PositiveInfinity));
                rowHeight = Math.Max(rowHeight, child.DesiredSize.Height);
            }

            if (rowStart > 0)
            {
                totalHeight += Math.Max(0, VerticalSpacing);
            }
            totalHeight += rowHeight;
        }

        return new Size(width, totalHeight);
    }

    protected override Size ArrangeOverride(Size finalSize)
    {
        double width = Math.Max(0, finalSize.Width);
        int columns = ColumnCount(width);
        double horizontalSpacing = Math.Max(0, HorizontalSpacing);
        double verticalSpacing = Math.Max(0, VerticalSpacing);
        double itemWidth = ItemWidth(width, columns);
        double y = 0;

        for (int rowStart = 0; rowStart < Children.Count; rowStart += columns)
        {
            double rowHeight = 0;
            int rowEnd = Math.Min(rowStart + columns, Children.Count);
            for (int index = rowStart; index < rowEnd; index++)
            {
                rowHeight = Math.Max(rowHeight, Children[index].DesiredSize.Height);
            }

            for (int index = rowStart; index < rowEnd; index++)
            {
                int column = index - rowStart;
                double x = column * (itemWidth + horizontalSpacing);
                Children[index].Arrange(new Rect(x, y, itemWidth, rowHeight));
            }

            y += rowHeight + verticalSpacing;
        }

        return finalSize;
    }

    private int ColumnCount(double availableWidth)
    {
        double minItemWidth = Math.Max(1, MinItemWidth);
        double spacing = Math.Max(0, HorizontalSpacing);
        int columns = (int)Math.Floor((availableWidth + spacing) / (minItemWidth + spacing));
        return Math.Clamp(columns, 1, Math.Max(1, Children.Count));
    }

    private double ItemWidth(double availableWidth, int columns) =>
        Math.Max(0, (availableWidth - Math.Max(0, HorizontalSpacing) * (columns - 1)) / columns);

    private static void OnLayoutPropertyChanged(
        DependencyObject sender,
        DependencyPropertyChangedEventArgs args)
    {
        if (sender is ResponsiveGridPanel panel)
        {
            panel.InvalidateMeasure();
            panel.InvalidateArrange();
        }
    }
}
