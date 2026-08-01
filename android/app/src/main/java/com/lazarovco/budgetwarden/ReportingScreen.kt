package com.lazarovco.budgetwarden

import androidx.compose.foundation.background
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.inset
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.Dp
import com.lazarovco.budgetwarden.domain.AmountMode
import com.lazarovco.budgetwarden.domain.Budget
import com.lazarovco.budgetwarden.domain.CategoryType
import com.lazarovco.budgetwarden.domain.Money
import com.lazarovco.budgetwarden.domain.title
import com.lazarovco.budgetwarden.core.BWReportingAmountMode
import com.lazarovco.budgetwarden.core.BWReportingComparisonRow
import com.lazarovco.budgetwarden.core.BWReportingComponent
import com.lazarovco.budgetwarden.core.BWReportingSummary
import com.lazarovco.budgetwarden.core.buildReportingSummary
import kotlin.math.cos
import kotlin.math.sin

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun ReportingScreen(
    budget: Budget,
    currencyCode: String,
    modifier: Modifier = Modifier,
) {
    var mode by rememberSaveable { mutableStateOf(AmountMode.PLANNED) }
    val summary = buildReportingSummary(budget)
    val expenseColor = MaterialTheme.colorScheme.error
    val savingsColor = MaterialTheme.colorScheme.tertiary
    val debtColor = MaterialTheme.colorScheme.primary
    val comparison = BWReportingComparisonRow.entries.map { row ->
        ReportingBar(
            title = when (row) {
                BWReportingComparisonRow.INCOME -> stringResource(R.string.income)
                BWReportingComparisonRow.PLANNED -> stringResource(R.string.planned)
                BWReportingComparisonRow.ACTUAL -> stringResource(R.string.actual)
            },
            slices = summary.comparisonSegments
                .filter { it.row == row && it.amount.value > 0 }
                .map { segment ->
                    ReportingSlice(
                        title = when (segment.component) {
                            BWReportingComponent.INCOME -> stringResource(R.string.income)
                            BWReportingComponent.EXPENSES -> stringResource(R.string.expenses)
                            BWReportingComponent.SAVINGS -> stringResource(R.string.savings)
                            BWReportingComponent.DEBT -> stringResource(R.string.debt)
                        },
                        amount = segment.amount.value,
                        color = when (segment.component) {
                            BWReportingComponent.INCOME, BWReportingComponent.SAVINGS -> savingsColor
                            BWReportingComponent.EXPENSES -> expenseColor
                            BWReportingComponent.DEBT -> debtColor
                        },
                    )
                },
        )
    }
    Column(
        modifier = modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(30.dp),
    ) {
        Box(modifier = Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
            SingleChoiceSegmentedButtonRow {
                AmountMode.entries.forEachIndexed { index, item ->
                    SegmentedButton(
                        selected = mode == item,
                        onClick = { mode = item },
                        shape = SegmentedButtonDefaults.itemShape(index, AmountMode.entries.size),
                    ) { Text(item.title) }
                }
            }
        }
        MetricGrid(summary, currencyCode)
        val charts = listOf(ReportingChart.Comparison, ReportingChart.Allocation) +
            CategoryType.entries.map(ReportingChart::CategoryBreakdown)
        ReportingChartGrid(charts = charts) { chart, chartModifier ->
            when (chart) {
                ReportingChart.Comparison -> ComparisonChart(comparison, chartModifier)
                ReportingChart.Allocation -> DonutChartSection(
                    title = stringResource(R.string.amount_allocation, mode.title),
                    emptyTitle = stringResource(R.string.no_allocation_amounts, mode.title.lowercase()),
                    segments = summary.allocationSegments
                        .filter { it.amountMode == mode.coreMode && it.amount.value > 0 }
                        .map { it.categoryType.title to it.amount.value },
                    currencyCode = currencyCode,
                    modifier = chartModifier,
                )
                is ReportingChart.CategoryBreakdown -> DonutChartSection(
                    title = stringResource(R.string.category_breakdown, chart.type.title),
                    emptyTitle = stringResource(R.string.no_category_amounts, mode.title.lowercase(), chart.type.title.lowercase()),
                    segments = summary.categorySegments
                        .filter {
                            it.categoryType == chart.type &&
                                it.amountMode == mode.coreMode &&
                                it.amount.value > 0
                        }
                        .map { it.title to it.amount.value },
                    currencyCode = currencyCode,
                    modifier = chartModifier,
                )
            }
        }
    }
}

@Composable
private fun MetricGrid(summary: BWReportingSummary, currencyCode: String) {
    val income = summary.totals.income.value
    val planned = summary.totals.plannedSpending.value
    val actual = summary.totals.actualSpending.value
    val left = summary.totals.leftToBudget
    val metrics = listOf(
        ReportingMetric(stringResource(R.string.income), Money.format(income, currencyCode)),
        ReportingMetric(stringResource(R.string.planned_spending), Money.format(planned, currencyCode), isError = planned > income),
        ReportingMetric(stringResource(R.string.actual_spending), Money.format(actual, currencyCode), isError = actual > planned, isPositive = actual <= planned),
        ReportingMetric(
            stringResource(R.string.savings),
            Money.format(summary.totals.plannedSavings.value, currencyCode),
        ),
        ReportingMetric(stringResource(R.string.left_to_budget), Money.formatSigned(left, currencyCode), isError = left < 0),
    )
    BoxWithConstraints(Modifier.fillMaxWidth()) {
        val columns = when {
            maxWidth >= 790.dp -> 5
            maxWidth >= 630.dp -> 4
            maxWidth >= 470.dp -> 3
            else -> 2
        }
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            metrics.chunked(columns).forEach { rowMetrics ->
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    rowMetrics.forEach { metric -> MetricCard(metric, Modifier.weight(1f)) }
                    repeat(columns - rowMetrics.size) { Spacer(Modifier.weight(1f)) }
                }
            }
        }
    }
}

private val AmountMode.coreMode: BWReportingAmountMode
    get() = when (this) {
        AmountMode.PLANNED -> BWReportingAmountMode.PLANNED
        AmountMode.ACTUAL -> BWReportingAmountMode.ACTUAL
    }

private data class ReportingMetric(
    val title: String,
    val value: String,
    val isError: Boolean = false,
    val isPositive: Boolean = false,
)

@Composable
private fun MetricCard(metric: ReportingMetric, modifier: Modifier = Modifier) {
    Card(
        modifier = modifier,
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainerLow),
    ) {
        Column(modifier = Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(metric.title, style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1)
            Text(
                metric.value,
                style = MaterialTheme.typography.titleMedium,
                fontWeight = FontWeight.SemiBold,
                color = when { metric.isError -> MaterialTheme.colorScheme.error; metric.isPositive -> MaterialTheme.colorScheme.tertiary; else -> MaterialTheme.colorScheme.onSurface },
                maxLines = 1,
            )
        }
    }
}

private data class ReportingSlice(val title: String, val amount: Long, val color: Color)
private data class ReportingBar(val title: String, val slices: List<ReportingSlice>)
private sealed interface ReportingChart {
    data object Comparison : ReportingChart
    data object Allocation : ReportingChart
    data class CategoryBreakdown(val type: CategoryType) : ReportingChart
}

@Composable
private fun ReportingChartGrid(
    charts: List<ReportingChart>,
    content: @Composable (ReportingChart, Modifier) -> Unit,
) {
    BoxWithConstraints(Modifier.fillMaxWidth()) {
        val columns = if (maxWidth >= 700.dp) 2 else 1
        Column(verticalArrangement = Arrangement.spacedBy(30.dp)) {
            charts.chunked(columns).forEach { rowCharts ->
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                    rowCharts.forEach { chart -> content(chart, Modifier.weight(1f)) }
                    if (rowCharts.size < columns) Spacer(Modifier.weight(1f))
                }
            }
        }
    }
}

@Composable
private fun ReportingSection(title: String, modifier: Modifier = Modifier, content: @Composable () -> Unit) {
    Column(modifier, verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Text(title, style = MaterialTheme.typography.titleMedium)
        Card(colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainerLow)) {
            Column(Modifier.fillMaxWidth().padding(12.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) { content() }
        }
    }
}

@Composable
private fun ComparisonChart(bars: List<ReportingBar>, modifier: Modifier = Modifier) {
    val nonEmpty = bars.any { bar -> bar.slices.any { it.amount > 0 } }
    ReportingSection(stringResource(R.string.income_vs_allocation), modifier) {
        if (!nonEmpty) ReportingEmpty(stringResource(R.string.no_allocation_yet), 170.dp) else {
            val maximum = bars.maxOf { it.slices.sumOf(ReportingSlice::amount) }.coerceAtLeast(1)
            Column(Modifier.fillMaxWidth().height(170.dp), verticalArrangement = Arrangement.SpaceEvenly) {
                bars.forEach { bar ->
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        Text(bar.title, Modifier.width(64.dp), style = MaterialTheme.typography.labelMedium)
                        Row(Modifier.weight(1f).height(24.dp).clip(RoundedCornerShape(4.dp)).background(MaterialTheme.colorScheme.surfaceVariant)) {
                            bar.slices.filter { it.amount > 0 }.forEach { slice ->
                                Box(Modifier.weight(slice.amount.toFloat() / maximum).fillMaxSize().background(slice.color))
                            }
                            val remainder = maximum - bar.slices.sumOf(ReportingSlice::amount)
                            if (remainder > 0) Spacer(Modifier.weight(remainder.toFloat() / maximum))
                        }
                    }
                }
            }
            FlowRow(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                bars.flatMap(ReportingBar::slices).distinctBy(ReportingSlice::title).forEach { LegendSwatch(it.title, it.color) }
            }
        }
    }
}

@Composable
private fun DonutChartSection(title: String, emptyTitle: String, segments: List<Pair<String, Long>>, currencyCode: String, modifier: Modifier = Modifier) {
    val colors = reportingPalette()
    val allocationColors = mapOf(
        "Expenses" to MaterialTheme.colorScheme.error,
        "Savings" to MaterialTheme.colorScheme.tertiary,
        "Debt" to MaterialTheme.colorScheme.primary,
    )
    val slices = segments.filter { it.second > 0 }.mapIndexed { index, item ->
        ReportingSlice(item.first, item.second, allocationColors[item.first] ?: colors[index % colors.size])
    }
    val total = slices.sumOf(ReportingSlice::amount)
    val separatorColor = MaterialTheme.colorScheme.surfaceContainerLow
    ReportingSection(title, modifier) {
        if (total == 0L) ReportingEmpty(emptyTitle, 210.dp) else {
            val description = slices.joinToString { "${it.title} ${Money.format(it.amount, currencyCode)}" }
            Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
                Canvas(Modifier.width(184.dp).height(184.dp).semantics { contentDescription = description }) {
                    val stroke = size.minDimension * .21f
                    var start = -90f
                    inset(stroke / 2f) {
                        slices.forEach { slice ->
                            val sweep = 360f * slice.amount.toFloat() / total.toFloat()
                            drawArc(slice.color, start, sweep, false, style = Stroke(stroke, cap = StrokeCap.Butt))
                            start += sweep
                        }
                        if (slices.size > 1) {
                            val innerRadius = size.minDimension / 2f - stroke / 2f
                            val outerRadius = size.minDimension / 2f + stroke / 2f
                            var boundary = -90f
                            slices.forEach { slice ->
                                val radians = Math.toRadians(boundary.toDouble())
                                val directionX = cos(radians).toFloat()
                                val directionY = sin(radians).toFloat()
                                drawLine(
                                    color = separatorColor,
                                    start = Offset(center.x + directionX * innerRadius, center.y + directionY * innerRadius),
                                    end = Offset(center.x + directionX * outerRadius, center.y + directionY * outerRadius),
                                    strokeWidth = 2.dp.toPx(),
                                    cap = StrokeCap.Butt,
                                )
                                boundary += 360f * slice.amount.toFloat() / total.toFloat()
                            }
                        }
                    }
                }
            }
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                slices.forEach { slice -> LegendRow(slice, total, currencyCode) }
            }
        }
    }
}

@Composable
private fun LegendSwatch(title: String, color: Color) = Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
    Box(Modifier.width(8.dp).height(8.dp).background(color, RoundedCornerShape(2.dp)))
    Text(title, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
}

@Composable
private fun LegendRow(slice: ReportingSlice, total: Long, currencyCode: String) {
    val locale = LocalConfiguration.current.locales[0]
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        LegendSwatch(slice.title, slice.color)
        Spacer(Modifier.weight(1f))
        Text(Money.format(slice.amount, currencyCode), style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Text(String.format(locale, "%.1f%%", slice.amount * 100.0 / total), Modifier.width(52.dp), style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@Composable
private fun ReportingEmpty(title: String, height: Dp) = Box(Modifier.fillMaxWidth().height(height), contentAlignment = Alignment.Center) {
    Text(title, color = MaterialTheme.colorScheme.onSurfaceVariant)
}

@Composable
private fun reportingPalette() = listOf(
    MaterialTheme.colorScheme.primary,
    MaterialTheme.colorScheme.tertiary,
    MaterialTheme.colorScheme.error,
    MaterialTheme.colorScheme.secondary,
    MaterialTheme.colorScheme.primaryContainer,
    MaterialTheme.colorScheme.tertiaryContainer,
    MaterialTheme.colorScheme.errorContainer,
    MaterialTheme.colorScheme.secondaryContainer,
)
