/*
 * Budget Warden
 * Copyright (c) 2026 Lazarov & Co EOOD
 * Author: Nikola Lazarov
 *
 * Licensed under the Source-Available Educational License.
 * See the LICENSE file in the project root for full terms.
 *
 */

import BWAppleCore
import Charts
import SwiftUI

struct BWReportingView: View {
    let budget: BWBudget
    let currency: BWCurrency

    @State private var amountMode: BWReportingAmountMode = .planned

    var body: some View {
        switch reportingResult {
        case .success(let summary):
            reportingContent(summary)
        case .failure(let error):
            ContentUnavailableView(
                "Reporting Unavailable",
                systemImage: "exclamationmark.triangle",
                description: Text(error.localizedDescription)
            )
        }
    }

    private var reportingResult: Result<BWReportingSummary, Error> {
        Result { try BWCore.buildReportingSummary(budget: budget) }
    }

    private func reportingContent(_ summary: BWReportingSummary) -> some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    Picker("Reporting Amount", selection: $amountMode) {
                        ForEach(BWReportingAmountMode.allCases) { mode in
                            Text(mode.title)
                                .tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)

                    BWReportingMetricGrid(
                        summary: summary,
                        currency: currency
                    )

                    BWReportingChartGrid(columnCount: chartColumnCount(for: proxy.size.width)) {
                        BWIncomeVsAllocationChart(
                            summary: summary,
                            currency: currency
                        )

                        BWAllocationBreakdownChart(
                            title: "\(amountMode.title) Allocation",
                            emptyTitle: "No \(amountMode.title.lowercased()) allocation amounts yet",
                            segments: allocationSegments(summary),
                            currency: currency
                        )

                        ForEach(BWCategoryType.allCases, id: \.self) { categoryType in
                            BWAllocationBreakdownChart(
                                title: "\(categoryType.title()) Breakdown",
                                emptyTitle: "No \(amountMode.title.lowercased()) \(categoryType.title().lowercased()) amounts yet",
                                segments: categorySegments(
                                    for: categoryType,
                                    summary: summary
                                ),
                                currency: currency
                            )
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.bottom)
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Reporting")
    }

    private func chartColumnCount(for width: CGFloat) -> Int {
        width >= 700 ? 2 : 1
    }

    private func allocationSegments(
        _ summary: BWReportingSummary
    ) -> [BWReportingSegment] {
        summary.allocationSegments(amountMode: amountMode).map { segment in
            BWReportingSegment(
                title: segment.categoryType.title(),
                amount: segment.amount.unsignedValue,
                tint: tint(for: segment.categoryType)
            )
        }
    }

    private func categorySegments(
        for categoryType: BWCategoryType,
        summary: BWReportingSummary
    ) -> [BWReportingSegment] {
        summary.categorySegments(
            categoryType: categoryType,
            amountMode: amountMode
        )
        .enumerated()
        .map { index, segment in
                BWReportingSegment(
                    title: segment.title,
                    amount: segment.amount.unsignedValue,
                    tint: BWReportingSegment.palette[index % BWReportingSegment.palette.count]
                )
        }
    }

    private func tint(for categoryType: BWCategoryType) -> Color {
        switch categoryType {
            case .expenses:
                return .orange
            case .savings:
                return .green
            case .debt:
                return .blue
            case .income:
                return .primary
        }
    }
}

private struct BWReportingChartGrid: Layout {
    let columnCount: Int
    private let horizontalSpacing: CGFloat = 16
    private let verticalSpacing: CGFloat = 30

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let width = proposal.width ?? 0
        let rowHeights = rowHeights(for: subviews, width: width)
        let totalSpacing = CGFloat(max(0, rowHeights.count - 1)) * verticalSpacing
        let height = rowHeights.reduce(0, +) + totalSpacing

        return CGSize(width: width, height: height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let resolvedColumnCount = max(1, columnCount)
        let columnWidth = columnWidth(for: bounds.width)
        var y = bounds.minY

        for rowStart in stride(from: 0, to: subviews.count, by: resolvedColumnCount) {
            let rowEnd = min(rowStart + resolvedColumnCount, subviews.count)
            let rowSubviews = subviews[rowStart..<rowEnd]
            let rowHeight = rowSubviews.map { subview in
                subview.sizeThatFits(ProposedViewSize(width: columnWidth, height: nil)).height
            }
            .max() ?? 0

            for (offset, subview) in rowSubviews.enumerated() {
                let x = bounds.minX + CGFloat(offset) * (columnWidth + horizontalSpacing)
                subview.place(
                    at: CGPoint(x: x, y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(width: columnWidth, height: rowHeight)
                )
            }

            y += rowHeight + verticalSpacing
        }
    }

    private func rowHeights(for subviews: Subviews, width: CGFloat) -> [CGFloat] {
        let resolvedColumnCount = max(1, columnCount)
        let columnWidth = columnWidth(for: width)

        return stride(from: 0, to: subviews.count, by: resolvedColumnCount).map { rowStart in
            let rowEnd = min(rowStart + resolvedColumnCount, subviews.count)

            return subviews[rowStart..<rowEnd].map { subview in
                subview.sizeThatFits(ProposedViewSize(width: columnWidth, height: nil)).height
            }
            .max() ?? 0
        }
    }

    private func columnWidth(for width: CGFloat) -> CGFloat {
        let resolvedColumnCount = max(1, columnCount)
        let totalSpacing = CGFloat(resolvedColumnCount - 1) * horizontalSpacing

        return max(0, (width - totalSpacing) / CGFloat(resolvedColumnCount))
    }
}

private struct BWReportingSegment: Identifiable {
    let title: String
    let amount: UInt64
    let tint: Color

    var id: String {
        title
    }

    static let palette: [Color] = [
        .blue,
        .green,
        .orange,
        .purple,
        .pink,
        .teal,
        .red,
        .indigo
    ]
}

private struct BWReportingComparisonSegment: Identifiable {
    let rowTitle: String
    let componentTitle: String
    let amount: UInt64
    let tint: Color

    var id: String {
        "\(rowTitle)-\(componentTitle)"
    }
}

private struct BWReportingMetricGrid: View {
    let summary: BWReportingSummary
    let currency: BWCurrency

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
            columns: [GridItem(.adaptive(minimum: 150), spacing: 12, alignment: .topLeading)],
            alignment: .leading,
            spacing: 12
        ) {
            BWReportingMetricView(title: "Income", value: incomeTotal, currency: currency)
            BWReportingMetricView(
                title: "Planned Spending",
                value: plannedSpendingTotal,
                valueColor: plannedSpendingTotal > incomeTotal ? .red : .primary,
                currency: currency
            )
            BWReportingMetricView(
                title: "Actual Spending",
                value: actualSpendingTotal,
                valueColor: actualSpendingTotal > plannedSpendingTotal ? .red : .green,
                currency: currency
            )
            BWReportingMetricView(title: "Savings", value: plannedSavingsTotal, currency: currency)

            BWReportingMetricView(
                title: "Left to Budget",
                signedValue: leftToBudgetTotal,
                valueColor: leftToBudgetTotal < 0 ? .red : .primary,
                currency: currency
            )
        }
    }

}

private struct BWIncomeVsAllocationChart: View {
    let summary: BWReportingSummary
    let currency: BWCurrency

    private var segments: [BWReportingComparisonSegment] {
        summary.comparisonSegments.map { segment in
            BWReportingComparisonSegment(
                rowTitle: segment.row.title,
                componentTitle: segment.component.title,
                amount: segment.amount.unsignedValue,
                tint: tint(for: segment.component)
            )
        }
    }

    var body: some View {
        BWReportingSection(title: "Income vs Allocation") {
            if segments.isEmpty {
                BWReportingEmptyView(title: "No allocation amounts yet", minHeight: 170)
            } else {
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
                            AxisValueLabel(formattedChartAmount(amount))
                        }
                    }
                }
                .frame(height: 170)

                HStack(spacing: 10) {
                    BWReportingLegendSwatch(title: "Income", tint: .green)
                    BWReportingLegendSwatch(title: "Expenses", tint: .orange)
                    BWReportingLegendSwatch(title: "Savings", tint: .green)
                    BWReportingLegendSwatch(title: "Debt", tint: .blue)
                }
            }
        }
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

    private func tint(for component: BWReportingComponent) -> Color {
        switch component {
            case .income, .savings:
                return .green
            case .expenses:
                return .orange
            case .debt:
                return .blue
        }
    }
}

private struct BWAllocationBreakdownChart: View {
    let title: String
    let emptyTitle: String
    let segments: [BWReportingSegment]
    let currency: BWCurrency

    private var total: UInt64 {
        UInt64.sumMoneyAmounts(segments.map(\.amount)) ?? UInt64.max
    }

    var body: some View {
        BWReportingSection(title: title) {
            if total == 0 {
                BWReportingEmptyView(title: emptyTitle, minHeight: 210)
            } else {
                Chart(segments) { segment in
                    SectorMark(
                        angle: .value("Amount", chartAmount(segment.amount)),
                        innerRadius: .ratio(0.58),
                        angularInset: 1.5
                    )
                    .foregroundStyle(segment.tint)
                }
                .chartLegend(.hidden)
                .frame(height: 210)

                VStack(alignment: .leading, spacing: 8) {
                    ForEach(segments) { segment in
                        BWReportingLegendRow(
                            segment: segment,
                            total: total,
                            currency: currency
                        )
                    }
                }
            }
        }
    }
}

private struct BWReportingMetricView: View {
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
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .foregroundStyle(valueColor)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 8, style: .continuous))
    }
}

private struct BWReportingSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)

            VStack(alignment: .leading, spacing: 12) {
                content
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 8, style: .continuous))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct BWReportingLegendSwatch: View {
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

private struct BWReportingLegendRow: View {
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
                .lineLimit(1)

            Text(percentText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 44, alignment: .trailing)
        }
    }
}

private struct BWReportingEmptyView: View {
    let title: String
    let minHeight: CGFloat

    var body: some View {
        Text(title)
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: minHeight)
    }
}

private func chartAmount(_ amount: UInt64) -> Double {
    Double(amount) / 100
}
