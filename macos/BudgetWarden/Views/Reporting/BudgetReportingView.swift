/* 
 * Budget Warden
 * Copyright (c) 2026 Lazarov & Co EOOD
 * Author: Nikola Lazarov
 *
 * Licensed under the Source-Available Educational License. 
 * See the LICENSE file in the project root for full terms.
 *
 */

import SwiftUI

struct BudgetReportingView: View {
    @ObservedObject var store: BWStore
    let budgetURL: URL
    let currency: AppCurrency
    @Binding var isExpanded: Bool
    let scope: ReportingScope

    private var outflowComparisonSegments: [OutflowComparisonSegment] {
        let income = store.categoryTotal(type: .income, field: .planned, in: budgetURL)

        return [
            OutflowComparisonSegment(
                rowTitle: "Income",
                componentTitle: "Income",
                amount: income,
                tint: Color(nsColor: .systemGreen)
            ),
            OutflowComparisonSegment(
                rowTitle: "Planned Allocation",
                componentTitle: "Expenses",
                amount: store.categoryTotal(type: .expenses, field: .planned, in: budgetURL),
                tint: Color(nsColor: .systemOrange)
            ),
            OutflowComparisonSegment(
                rowTitle: "Planned Allocation",
                componentTitle: "Savings",
                amount: store.categoryTotal(type: .savings, field: .planned, in: budgetURL),
                tint: Color(nsColor: .systemGreen)
            ),
            OutflowComparisonSegment(
                rowTitle: "Planned Allocation",
                componentTitle: "Debt",
                amount: store.categoryTotal(type: .debt, field: .planned, in: budgetURL),
                tint: Color(nsColor: .systemBlue)
            ),
            OutflowComparisonSegment(
                rowTitle: "Actual Allocation",
                componentTitle: "Expenses",
                amount: store.categoryTotal(type: .expenses, field: .actual, in: budgetURL),
                tint: Color(nsColor: .systemOrange)
            ),
            OutflowComparisonSegment(
                rowTitle: "Actual Allocation",
                componentTitle: "Savings",
                amount: store.categoryTotal(type: .savings, field: .actual, in: budgetURL),
                tint: Color(nsColor: .systemGreen)
            ),
            OutflowComparisonSegment(
                rowTitle: "Actual Allocation",
                componentTitle: "Debt",
                amount: store.categoryTotal(type: .debt, field: .actual, in: budgetURL),
                tint: Color(nsColor: .systemBlue)
            )
        ]
    }

    private var outflowComparisonTotals: [OutflowComparisonTotal] {
        let income = store.categoryTotal(type: .income, field: .planned, in: budgetURL)
        let outflowTypes: [BudgetCategoryType] = [.expenses, .savings, .debt]
        let planned = outflowTypes.reduce(0) { total, type in
            total + store.categoryTotal(type: type, field: .planned, in: budgetURL)
        }
        let actual = outflowTypes.reduce(0) { total, type in
            total + store.categoryTotal(type: type, field: .actual, in: budgetURL)
        }

        return [
            OutflowComparisonTotal(title: "Income", amount: income),
            OutflowComparisonTotal(title: "Planned", amount: planned),
            OutflowComparisonTotal(title: "Actual", amount: actual)
        ]
    }

    private var outflowComparisonLegendItems: [OutflowComparisonLegendItem] {
        [
            OutflowComparisonLegendItem(title: "Income", tint: Color(nsColor: .systemGreen)),
            OutflowComparisonLegendItem(title: "Expenses", tint: Color(nsColor: .systemOrange)),
            OutflowComparisonLegendItem(title: "Savings", tint: Color(nsColor: .systemGreen)),
            OutflowComparisonLegendItem(title: "Debt", tint: Color(nsColor: .systemBlue))
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if scope == .inspector {
                Label("Budget Reporting", systemImage: "chart.pie")
                    .font(.headline)
                    .padding(14)

                Divider()
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ReportingMetricGrid(
                        store: store,
                        budgetURL: budgetURL,
                        currency: currency,
                        scope: scope
                    )

                    if scope == .inspector {
                        inspectorChartStack
                    } else {
                        fullPageChartGrid
                    }
                }
                .padding(14)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .accessibilityIdentifier("budget-reporting-\(scope.accessibilityID)")
    }

    private var inspectorChartStack: some View {
        VStack(alignment: .leading, spacing: 18) {
            incomeVsAllocationSection
            allocationBreakdownSection
        }
    }

    private var fullPageChartGrid: some View {
        ViewThatFits(in: .horizontal) {
            chartGrid(columnCount: 3)
            chartGrid(columnCount: 2)
            chartGrid(columnCount: 1)
        }
    }

    private func chartGrid(columnCount: Int) -> some View {
        let chartCount = 6
        let spacing: CGFloat = 20
        let minimumColumnWidth: CGFloat = 320
        let minimumGridWidth = (CGFloat(columnCount) * minimumColumnWidth) + (CGFloat(columnCount - 1) * spacing)

        return Grid(alignment: .topLeading, horizontalSpacing: spacing, verticalSpacing: spacing) {
            ForEach(Array(stride(from: 0, to: chartCount, by: columnCount)), id: \.self) { rowStart in
                GridRow(alignment: .top) {
                    ForEach(rowStart..<min(rowStart + columnCount, chartCount), id: \.self) { index in
                        chartSection(at: index)
                            .frame(minWidth: minimumColumnWidth, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                }
            }
        }
        .environment(\.reportChartFillsAvailableHeight, true)
        .frame(minWidth: minimumGridWidth, maxWidth: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func chartSection(at index: Int) -> some View {
        switch index {
        case 0:
            incomeVsAllocationSection
        case 1:
            allocationBreakdownSection
        case 2:
            CategoryBreakdownSection(
                title: "Income Breakdown",
                emptyTitle: "No income amounts yet",
                currency: currency
            ) { mode in
                categoryBreakdownSegments(for: .income, mode: mode)
            }
        case 3:
            CategoryBreakdownSection(
                title: "Expenses Breakdown",
                emptyTitle: "No expense amounts yet",
                currency: currency
            ) { mode in
                categoryBreakdownSegments(for: .expenses, mode: mode)
            }
        case 4:
            CategoryBreakdownSection(
                title: "Savings Breakdown",
                emptyTitle: "No savings amounts yet",
                currency: currency
            ) { mode in
                categoryBreakdownSegments(for: .savings, mode: mode)
            }
        default:
            CategoryBreakdownSection(
                title: "Debt Breakdown",
                emptyTitle: "No debt amounts yet",
                currency: currency
            ) { mode in
                categoryBreakdownSegments(for: .debt, mode: mode)
            }
        }
    }

    private var incomeVsAllocationSection: some View {
        IncomeVsAllocationChart(
            segments: outflowComparisonSegments,
            legendItems: outflowComparisonLegendItems,
            totals: outflowComparisonTotals,
            currency: currency
        )
    }

    private var allocationBreakdownSection: some View {
        AllocationBreakdownSection(
            segments: allocationBreakdownSegments,
            currency: currency
        )
    }

    private func allocationBreakdownSegments(for mode: AllocationBreakdownMode) -> [AllocationBreakdownSegment] {
        [
            AllocationBreakdownSegment(
                title: "Expenses",
                amount: store.categoryTotal(type: .expenses, field: mode.amountField, in: budgetURL),
                tint: Color(nsColor: .systemOrange)
            ),
            AllocationBreakdownSegment(
                title: "Savings",
                amount: store.categoryTotal(type: .savings, field: mode.amountField, in: budgetURL),
                tint: Color(nsColor: .systemGreen)
            ),
            AllocationBreakdownSegment(
                title: "Debt",
                amount: store.categoryTotal(type: .debt, field: mode.amountField, in: budgetURL),
                tint: Color(nsColor: .systemBlue)
            )
        ]
    }

    private func categoryBreakdownSegments(
        for type: BudgetCategoryType,
        mode: AllocationBreakdownMode
    ) -> [AllocationBreakdownSegment] {
        let colors: [Color] = [
            Color(nsColor: .systemGreen),
            Color(nsColor: .systemTeal),
            Color(nsColor: .systemMint),
            Color(nsColor: .systemCyan),
            Color(nsColor: .systemBlue),
            Color(nsColor: .systemPurple)
        ]

        return store.categoryIDs(for: type, in: budgetURL).enumerated().map { index, categoryID in
            let category = store.category(categoryID, in: budgetURL)

            return AllocationBreakdownSegment(
                title: category?.title.swiftString() ?? "",
                amount: category?.amount(mode.amountField) ?? 0,
                tint: colors[index % colors.count]
            )
        }
    }
}

private extension ReportingScope {
    var accessibilityID: Swift.String {
        switch self {
        case .inspector:
            return "inspector"
        case .fullPage:
            return "full-page"
        }
    }
}
