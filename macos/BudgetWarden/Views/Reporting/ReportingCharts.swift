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

struct IncomeVsAllocationChart: View {
    let segments: [OutflowComparisonSegment]
    let legendItems: [OutflowComparisonLegendItem]
    let totals: [OutflowComparisonTotal]
    let currency: AppCurrency

    var body: some View {
        ReportChartSection(title: "Income vs Allocation") {
            VStack(alignment: .leading, spacing: 10) {
                Chart(segments) { segment in
                    BarMark(
                        x: .value("Amount", chartAmount(segment.amount)),
                        y: .value("Measure", segment.rowTitle)
                    )
                    .foregroundStyle(segment.tint)
                }
                .chartLegend(.hidden)
                .chartXAxis {
                    amountAxisMarks()
                }
                .frame(height: 150)

                HStack(spacing: 8) {
                    ForEach(legendItems) { item in
                        ChartLegendSwatch(title: item.title, tint: item.tint)
                    }
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

    private func amountAxisMarks() -> some AxisContent {
        AxisMarks { value in
            AxisGridLine()
            AxisTick()

            if let amount = value.as(Double.self) {
                AxisValueLabel(formattedChartAmount(amount))
            }
        }
    }

    private func formattedChartAmount(_ amount: Double) -> Swift.String {
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

struct AllocationBreakdownSection: View {
    let segments: (AllocationBreakdownMode) -> [AllocationBreakdownSegment]
    let currency: AppCurrency

    @State private var selectedMode: AllocationBreakdownMode = .planned

    private var selectedSegments: [AllocationBreakdownSegment] {
        segments(selectedMode)
    }

    private var selectedTotal: UInt64 {
        selectedSegments.total(\.amount)
    }

    var body: some View {
        ReportChartSection(title: "Allocation Breakdown") {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Breakdown", selection: $selectedMode) {
                    ForEach(AllocationBreakdownMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                if selectedTotal == 0 {
                    emptyState("No allocation amounts yet")
                } else {
                    doughnutChart
                    legendRows
                }
            }
        }
    }

    private var doughnutChart: some View {
        Chart(selectedSegments) { segment in
            SectorMark(
                angle: .value("Amount", chartAmount(segment.amount)),
                innerRadius: .ratio(0.58),
                angularInset: 1.5
            )
            .foregroundStyle(segment.tint)
        }
        .chartLegend(.hidden)
        .frame(height: 180)
    }

    private var legendRows: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(selectedSegments) { segment in
                AllocationBreakdownLegendRow(
                    segment: segment,
                    total: selectedTotal,
                    currency: currency
                )
            }
        }
    }
}

struct CategoryBreakdownSection: View {
    let title: Swift.String
    let emptyTitle: Swift.String
    let currency: AppCurrency
    let segments: (AllocationBreakdownMode) -> [AllocationBreakdownSegment]

    @State private var selectedMode: AllocationBreakdownMode = .planned

    private var selectedSegments: [AllocationBreakdownSegment] {
        segments(selectedMode)
    }

    private var selectedTotal: UInt64 {
        selectedSegments.total(\.amount)
    }

    var body: some View {
        ReportChartSection(title: title) {
            VStack(alignment: .leading, spacing: 12) {
                Picker(title, selection: $selectedMode) {
                    ForEach(AllocationBreakdownMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                if selectedTotal == 0 {
                    emptyState(emptyTitle)
                } else {
                    doughnutChart
                    legendRows
                }
            }
        }
    }

    private var doughnutChart: some View {
        Chart(selectedSegments) { segment in
            SectorMark(
                angle: .value("Amount", chartAmount(segment.amount)),
                innerRadius: .ratio(0.58),
                angularInset: 1.5
            )
            .foregroundStyle(segment.tint)
        }
        .chartLegend(.hidden)
        .frame(height: 180)
    }

    private var legendRows: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(selectedSegments) { segment in
                AllocationBreakdownLegendRow(
                    segment: segment,
                    total: selectedTotal,
                    currency: currency
                )
            }
        }
    }
}

private func emptyState(_ title: Swift.String) -> some View {
    Text(title)
        .font(.callout)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, minHeight: 180)
}

private func chartAmount(_ amount: UInt64) -> Double {
    Double(amount) / 100
}
