/* 
 * Budget Warden
 * Copyright (c) 2026 Lazarov & Co EOOD
 * Author: Nikola Lazarov
 *
 * Licensed under the Source-Available Educational License. 
 * See the LICENSE file in the project root for full terms.
 *
 */

import Charts
import SwiftUI

enum BWReportingAmountMode: String, CaseIterable, Identifiable {
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

    var id: String {
        title
    }
}

struct BWReportingMetricGrid: View {
    let budget: BWBudget
    let currency: BWCurrency
    let scope: BWReportingScope

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

    private var leftToBudgetTotal: Int64 {
        Int64(incomeTotal) - Int64(plannedSpendingTotal) - Int64(plannedSavingsTotal)
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
            BWReportingMetricView(
                title: "Left to Budget",
                signedValue: leftToBudgetTotal,
                valueColor: leftToBudgetTotal < 0 ? Color(nsColor: .systemRed) : .primary,
                currency: currency
            )
        }
    }

    private func total(
        for types: Set<BWCategoryType>,
        amount: KeyPath<BWCategory, UInt64>
    ) -> UInt64 {
        budget.categories
            .filter { types.contains($0.categoryType) }
            .reduce(0) { $0 + $1[keyPath: amount] }
    }
}

struct BWIncomeVsAllocationChart: View {
    let budget: BWBudget
    let currency: BWCurrency
    let scope: BWReportingScope

    private var segments: [BWReportingComparisonSegment] {
        [
            BWReportingComparisonSegment(
                rowTitle: "Income",
                componentTitle: "Income",
                amount: total(for: [.income], amount: \.amountPlanned),
                tint: Color(nsColor: .systemGreen)
            ),
            BWReportingComparisonSegment(
                rowTitle: "Planned Allocation",
                componentTitle: "Expenses",
                amount: total(for: [.expenses], amount: \.amountPlanned),
                tint: Color(nsColor: .systemOrange)
            ),
            BWReportingComparisonSegment(
                rowTitle: "Planned Allocation",
                componentTitle: "Savings",
                amount: total(for: [.savings], amount: \.amountPlanned),
                tint: Color(nsColor: .systemGreen)
            ),
            BWReportingComparisonSegment(
                rowTitle: "Planned Allocation",
                componentTitle: "Debt",
                amount: total(for: [.debt], amount: \.amountPlanned),
                tint: Color(nsColor: .systemBlue)
            ),
            BWReportingComparisonSegment(
                rowTitle: "Actual Allocation",
                componentTitle: "Expenses",
                amount: total(for: [.expenses], amount: \.amountActual),
                tint: Color(nsColor: .systemOrange)
            ),
            BWReportingComparisonSegment(
                rowTitle: "Actual Allocation",
                componentTitle: "Savings",
                amount: total(for: [.savings], amount: \.amountActual),
                tint: Color(nsColor: .systemGreen)
            ),
            BWReportingComparisonSegment(
                rowTitle: "Actual Allocation",
                componentTitle: "Debt",
                amount: total(for: [.debt], amount: \.amountActual),
                tint: Color(nsColor: .systemBlue)
            )
        ].filter { $0.amount > 0 }
    }

    private var totals: [BWReportingComparisonTotal] {
        let outflowTypes: Set<BWCategoryType> = [.expenses, .savings, .debt]

        return [
            BWReportingComparisonTotal(title: "Income", amount: total(for: [.income], amount: \.amountPlanned)),
            BWReportingComparisonTotal(title: "Planned", amount: total(for: outflowTypes, amount: \.amountPlanned)),
            BWReportingComparisonTotal(title: "Actual", amount: total(for: outflowTypes, amount: \.amountActual))
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
                            AxisValueLabel(formattedChartAmount(amount))
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

    private func total(
        for types: Set<BWCategoryType>,
        amount: KeyPath<BWCategory, UInt64>
    ) -> UInt64 {
        budget.categories
            .filter { types.contains($0.categoryType) }
            .reduce(0) { $0 + $1[keyPath: amount] }
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

struct BWAllocationBreakdownChart: View {
    let title: String
    let emptyTitle: String
    let segments: [BWReportingSegment]
    let currency: BWCurrency
    let scope: BWReportingScope

    private var total: UInt64 {
        segments.reduce(0) { $0 + $1.amount }
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
