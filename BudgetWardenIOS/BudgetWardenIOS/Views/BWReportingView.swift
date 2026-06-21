/*
 * Budget Warden
 * Copyright (c) 2026 Lazarov & Co EOOD
 * Author: Nikola Lazarov
 *
 * Licensed under the Source-Available Educational License.
 * See the LICENSE file in the project root for full terms.
 *
 */

import AppleCore
import Charts
import SwiftUI

struct BWReportingView: View {
    let budget: BWBudget
    let currency: BWCurrency

    @State private var amountMode: BWReportingAmountMode = .planned

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Picker("Reporting Amount", selection: $amountMode) {
                    ForEach(BWReportingAmountMode.allCases) { mode in
                        Text(mode.title)
                            .tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                BWReportingMetricGrid(
                    budget: budget,
                    currency: currency
                )

                BWIncomeVsAllocationChart(
                    budget: budget,
                    currency: currency
                )

                BWAllocationBreakdownChart(
                    title: "\(amountMode.title) Allocation",
                    emptyTitle: "No \(amountMode.title.lowercased()) allocation amounts yet",
                    segments: allocationSegments,
                    currency: currency
                )

                ForEach(BWCategoryType.allCases, id: \.self) { categoryType in
                    BWAllocationBreakdownChart(
                        title: "\(categoryType.title) Breakdown",
                        emptyTitle: "No \(amountMode.title.lowercased()) \(categoryType.title.lowercased()) amounts yet",
                        segments: categorySegments(for: categoryType),
                        currency: currency
                    )
                }
            }
            .padding()
        }
        .navigationTitle("Reporting")
    }

    private var allocationSegments: [BWReportingSegment] {
        [
            BWReportingSegment(
                title: "Expenses",
                amount: total(for: [.expenses], amount: amountMode.amountKeyPath),
                tint: .orange
            ),
            BWReportingSegment(
                title: "Savings",
                amount: total(for: [.savings], amount: amountMode.amountKeyPath),
                tint: .green
            ),
            BWReportingSegment(
                title: "Debt",
                amount: total(for: [.debt], amount: amountMode.amountKeyPath),
                tint: .blue
            )
        ]
        .filter { $0.amount > 0 }
    }

    private func categorySegments(for categoryType: BWCategoryType) -> [BWReportingSegment] {
        budget.categories
            .filter { $0.categoryType == categoryType && $0[keyPath: amountMode.amountKeyPath] > 0 }
            .sorted { $0.ordinal < $1.ordinal }
            .enumerated()
            .map { index, category in
                BWReportingSegment(
                    title: category.title,
                    amount: category[keyPath: amountMode.amountKeyPath],
                    tint: BWReportingSegment.palette[index % BWReportingSegment.palette.count]
                )
            }
    }

    private func total(
        for types: Set<BWCategoryType>,
        amount: KeyPath<BWCategory, UInt64>
    ) -> UInt64 {
        UInt64.sumMoneyAmounts(
            budget.categories
                .filter { types.contains($0.categoryType) }
                .map { $0[keyPath: amount] }
        ) ?? UInt64.max
    }
}

private enum BWReportingAmountMode: String, CaseIterable, Identifiable {
    case planned
    case actual

    var id: Self {
        self
    }

    var title: String {
        switch self {
            case .planned:
                return "Planned"
            case .actual:
                return "Actual"
        }
    }

    var amountKeyPath: KeyPath<BWCategory, UInt64> {
        switch self {
            case .planned:
                return \.amountPlanned
            case .actual:
                return \.amountActual
        }
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
    let budget: BWBudget
    let currency: BWCurrency

    private var incomeTotal: UInt64 {
        total(for: [.income], amount: \.amountPlanned)
    }

    private var plannedSpendingTotal: UInt64 {
        total(for: [.expenses, .debt], amount: \.amountPlanned)
    }

    private var actualSpendingTotal: UInt64 {
        total(for: [.expenses, .debt], amount: \.amountActual)
    }

    private var plannedSavingsTotal: UInt64 {
        total(for: [.savings], amount: \.amountPlanned)
    }

    private var leftToBudgetTotal: Int64? {
        guard
            let income = Int64(exactly: incomeTotal),
            let plannedSpending = Int64(exactly: plannedSpendingTotal),
            let plannedSavings = Int64(exactly: plannedSavingsTotal)
        else {
            return nil
        }

        let afterSpending = income.subtractingReportingOverflow(plannedSpending)

        guard !afterSpending.overflow else {
            return nil
        }

        let afterSavings = afterSpending.partialValue.subtractingReportingOverflow(plannedSavings)

        guard !afterSavings.overflow else {
            return nil
        }

        return afterSavings.partialValue
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

            if let leftToBudgetTotal {
                BWReportingMetricView(
                    title: "Left to Budget",
                    signedValue: leftToBudgetTotal,
                    valueColor: leftToBudgetTotal < 0 ? .red : .primary,
                    currency: currency
                )
            } else {
                BWReportingMetricView(
                    title: "Left to Budget",
                    valueText: "Too large",
                    valueColor: .red
                )
            }
        }
    }

    private func total(
        for types: Set<BWCategoryType>,
        amount: KeyPath<BWCategory, UInt64>
    ) -> UInt64 {
        UInt64.sumMoneyAmounts(
            budget.categories
                .filter { types.contains($0.categoryType) }
                .map { $0[keyPath: amount] }
        ) ?? UInt64.max
    }
}

private struct BWIncomeVsAllocationChart: View {
    let budget: BWBudget
    let currency: BWCurrency

    private var segments: [BWReportingComparisonSegment] {
        [
            BWReportingComparisonSegment(
                rowTitle: "Income",
                componentTitle: "Income",
                amount: total(for: [.income], amount: \.amountPlanned),
                tint: .green
            ),
            BWReportingComparisonSegment(
                rowTitle: "Planned",
                componentTitle: "Expenses",
                amount: total(for: [.expenses], amount: \.amountPlanned),
                tint: .orange
            ),
            BWReportingComparisonSegment(
                rowTitle: "Planned",
                componentTitle: "Savings",
                amount: total(for: [.savings], amount: \.amountPlanned),
                tint: .green
            ),
            BWReportingComparisonSegment(
                rowTitle: "Planned",
                componentTitle: "Debt",
                amount: total(for: [.debt], amount: \.amountPlanned),
                tint: .blue
            ),
            BWReportingComparisonSegment(
                rowTitle: "Actual",
                componentTitle: "Expenses",
                amount: total(for: [.expenses], amount: \.amountActual),
                tint: .orange
            ),
            BWReportingComparisonSegment(
                rowTitle: "Actual",
                componentTitle: "Savings",
                amount: total(for: [.savings], amount: \.amountActual),
                tint: .green
            ),
            BWReportingComparisonSegment(
                rowTitle: "Actual",
                componentTitle: "Debt",
                amount: total(for: [.debt], amount: \.amountActual),
                tint: .blue
            )
        ]
        .filter { $0.amount > 0 }
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

    private func total(
        for types: Set<BWCategoryType>,
        amount: KeyPath<BWCategory, UInt64>
    ) -> UInt64 {
        UInt64.sumMoneyAmounts(
            budget.categories
                .filter { types.contains($0.categoryType) }
                .map { $0[keyPath: amount] }
        ) ?? UInt64.max
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
        .background(.quaternary, in: .rect(cornerRadius: 8, style: .continuous))
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
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(.quaternary, in: .rect(cornerRadius: 8, style: .continuous))
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
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
