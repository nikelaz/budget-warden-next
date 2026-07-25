/* 
 * Budget Warden
 * Copyright (c) 2026 Lazarov & Co EOOD
 * Author: Nikola Lazarov
 *
 * Licensed under the Source-Available Educational License. 
 * See the LICENSE file in the project root for full terms.
 */

import Charts
import SwiftUI
import BWAppleCore

enum BWReportingScope {
    case inspector
    case fullPage

    var chartSpacing: CGFloat {
        switch self {
            case .inspector:
                return 16
            case .fullPage:
                return 20
        }
    }

    var metricMinimumWidth: CGFloat {
        switch self {
            case .inspector:
                return 130
            case .fullPage:
                return 170
        }
    }
}

struct BWReportingSegment: Identifiable {
    let title: String
    let amount: UInt64
    let tint: Color

    var id: String {
        title
    }

    static let palette: [Color] = [
        Color(nsColor: .systemBlue),
        Color(nsColor: .systemGreen),
        Color(nsColor: .systemOrange),
        Color(nsColor: .systemPurple),
        Color(nsColor: .systemPink),
        Color(nsColor: .systemTeal),
        Color(nsColor: .systemRed),
        Color(nsColor: .systemIndigo)
    ]
}

struct BWReportingComparisonSegment: Identifiable {
    let rowTitle: String
    let componentTitle: String
    let amount: UInt64
    let tint: Color

    var id: String {
        "\(rowTitle)-\(componentTitle)"
    }
}

struct BWReportingComparisonTotal: Identifiable {
    let title: String
    let amount: UInt64
    var id: String { title }
}

struct BWReportingMetricGrid: View {
    let summary: BWReportingSummary
    let currency: BWCurrency
    let scope: BWReportingScope

    private var incomeTotal: UInt64 {
        summary.totals.income.unsignedValue
    }

    private var plannedSpendingTotal: UInt64 {
        summary.totals.plannedSpending.unsignedValue
    }

    private var actualSpendingTotal: UInt64 {
        summary.totals.actualSpending.unsignedValue
    }

    private var plannedSavingsTotal: UInt64 {
        summary.totals.plannedSavings.unsignedValue
    }

    private var leftToBudgetTotal: Int64 {
        summary.totals.leftToBudget
    }

    var body: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: scope.metricMinimumWidth), spacing: scope.chartSpacing, alignment: .topLeading)],
            alignment: .leading,
            spacing: scope.chartSpacing
        ) {
            BWReportingMetricView(title: "Income", value: incomeTotal, currency: currency)
            BWReportingMetricView(
                title: "Planned Spending",
                value: plannedSpendingTotal,
                valueColor: plannedSpendingTotal > incomeTotal ? Color(nsColor: .systemRed) : .primary,
                currency: currency
            )
            BWReportingMetricView(
                title: "Actual Spending",
                value: actualSpendingTotal,
                valueColor: actualSpendingTotal > plannedSpendingTotal ? Color(nsColor: .systemRed) : Color(nsColor: .systemGreen),
                currency: currency
            )
            BWReportingMetricView(title: "Savings", value: plannedSavingsTotal, currency: currency)
            leftToBudgetMetric
        }
    }

    @ViewBuilder
    private var leftToBudgetMetric: some View {
        BWReportingMetricView(
            title: "Left to Budget",
            signedValue: leftToBudgetTotal,
            valueColor: leftToBudgetTotal < 0 ? Color(nsColor: .systemRed) : .primary,
            currency: currency
        )
    }

}

struct BWIncomeVsAllocationChart: View {
    let summary: BWReportingSummary
    let currency: BWCurrency
    let scope: BWReportingScope

    private var segments: [BWReportingComparisonSegment] {
        summary.comparisonSegments.map { segment in
            BWReportingComparisonSegment(
                rowTitle: rowTitle(for: segment.row),
                componentTitle: segment.component.title,
                amount: segment.amount.unsignedValue,
                tint: tint(for: segment.component)
            )
        }
    }

    private var totals: [BWReportingComparisonTotal] {
        [
            BWReportingComparisonTotal(
                title: "Income",
                amount: summary.totals.income.unsignedValue
            ),
            BWReportingComparisonTotal(
                title: "Planned",
                amount: summary.totals.plannedAllocation.unsignedValue
            ),
            BWReportingComparisonTotal(
                title: "Actual",
                amount: summary.totals.actualAllocation.unsignedValue
            )
        ]
    }

    var body: some View {
        BWReportingSection(title: "Income vs Allocation") {
            if segments.isEmpty {
                BWReportingEmptyView(title: "No allocation amounts yet", minHeight: chartHeight)
            }
            else {
                Chart(segments) { segment in
                    BarMark(
                        x: .value("Amount", chartAmount(segment.amount)),
                        y: .value("Measure", segment.rowTitle)
                    )
                    .foregroundStyle(segment.tint)
                }
                .chartLegend(.hidden)
                .chartXAxis {
                    AxisMarks { value in
                        AxisGridLine()
                        AxisTick()

                        if let amount = value.as(Double.self) {
                            AxisValueLabel(
                                formattedChartAmount(amount),
                                anchor: .center
                            )
                        }
                    }
                }
                .frame(height: chartHeight)

                HStack(spacing: 8) {
                    BWReportingLegendSwatch(title: "Income", tint: Color(nsColor: .systemGreen))
                    BWReportingLegendSwatch(title: "Expenses", tint: Color(nsColor: .systemOrange))
                    BWReportingLegendSwatch(title: "Savings", tint: Color(nsColor: .systemGreen))
                    BWReportingLegendSwatch(title: "Debt", tint: Color(nsColor: .systemBlue))
                }

                VStack(alignment: .leading, spacing: 3) {
                    ForEach(totals) { total in
                        Text("\(total.title): \(total.amount.formattedMoneyAmount(currency: currency))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }
        }
    }

    private var chartHeight: CGFloat {
        scope == .inspector ? 130 : 150
    }

    private func formattedChartAmount(_ amount: Double) -> String {
        let formatter = NumberFormatter()
        formatter.locale = .current
        formatter.numberStyle = .currency
        formatter.currencyCode = currency.rawValue
        formatter.currencySymbol = currency.symbol
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 2

        return formatter.string(from: NSNumber(value: amount)) ?? amount.formatted(.number.precision(.fractionLength(0...2)))
    }

    private func rowTitle(for row: BWReportingComparisonRow) -> String {
        switch row {
        case .income:
            "Income"
        case .planned:
            "Planned Allocation"
        case .actual:
            "Actual Allocation"
        }
    }

    private func tint(for component: BWReportingComponent) -> Color {
        switch component {
            case .income, .savings:
                return Color(nsColor: .systemGreen)
            case .expenses:
                return Color(nsColor: .systemOrange)
            case .debt:
                return Color(nsColor: .systemBlue)
        }
    }
}

struct BWAllocationBreakdownChart: View {
    let title: String
    let emptyTitle: String
    let segments: [BWReportingSegment]
    let currency: BWCurrency
    let scope: BWReportingScope

    private var total: UInt64 {
        UInt64.sumMoneyAmounts(segments.map(\.amount)) ?? UInt64.max
    }

    var body: some View {
        BWReportingSection(title: title) {
            if total == 0 {
                BWReportingEmptyView(title: emptyTitle, minHeight: chartHeight)
            }
            else {
                Chart(segments) { segment in
                    SectorMark(
                        angle: .value("Amount", chartAmount(segment.amount)),
                        innerRadius: .ratio(0.58),
                        angularInset: 1.5
                    )
                    .foregroundStyle(segment.tint)
                }
                .chartLegend(.hidden)
                .frame(height: chartHeight)

                VStack(alignment: .leading, spacing: 6) {
                    ForEach(segments) { segment in
                        BWReportingLegendRow(segment: segment, total: total, currency: currency)
                    }
                }
            }
        }
    }

    private var chartHeight: CGFloat {
        scope == .inspector ? 170 : 180
    }
}

struct BWReportingMetricView: View {
    let title: String
    let valueText: String
    var valueColor: Color = .primary

    init(title: String, valueText: String, valueColor: Color = .primary) {
        self.title = title
        self.valueText = valueText
        self.valueColor = valueColor
    }

    init(title: String, value: UInt64, valueColor: Color = .primary, currency: BWCurrency) {
        self.title = title
        self.valueText = value.formattedMoneyAmount(currency: currency)
        self.valueColor = valueColor
    }

    init(title: String, signedValue: Int64, valueColor: Color = .primary, currency: BWCurrency) {
        self.title = title
        let prefix = signedValue < 0 ? "-" : ""
        self.valueText = "\(prefix)\(UInt64(signedValue.magnitude).formattedMoneyAmount(currency: currency))"
        self.valueColor = valueColor
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(valueText)
                .font(.title3)
                .fontWeight(.semibold)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .foregroundStyle(valueColor)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .quaternarySystemFill))
        .clipShape(.rect(cornerRadius: 8, style: .continuous))
    }
}

struct BWReportingSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline)
                .fontWeight(.semibold)

            VStack(alignment: .leading, spacing: 10) {
                content
            }
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(nsColor: .quaternarySystemFill))
            .clipShape(.rect(cornerRadius: 8, style: .continuous))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct BWReportingLegendSwatch: View {
    let title: String
    let tint: Color

    var body: some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2)
                .fill(tint)
                .frame(width: 8, height: 8)

            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

struct BWReportingLegendRow: View {
    let segment: BWReportingSegment
    let total: UInt64
    let currency: BWCurrency

    private var percentText: String {
        guard total > 0 else {
            return "0%"
        }

        return (Double(segment.amount) / Double(total))
            .formatted(.percent.precision(.fractionLength(0...1)))
    }

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2)
                .fill(segment.tint)
                .frame(width: 8, height: 8)

            Text(segment.title)
                .font(.caption)
                .lineLimit(1)

            Spacer()

            Text(segment.amount.formattedMoneyAmount(currency: currency))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            Text(percentText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 44, alignment: .trailing)
        }
    }
}

struct BWReportingEmptyView: View {
    let title: String
    let minHeight: CGFloat

    var body: some View {
        Text(title)
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: minHeight)
    }
}

func chartAmount(_ amount: UInt64) -> Double {
    Double(amount) / 100
}
