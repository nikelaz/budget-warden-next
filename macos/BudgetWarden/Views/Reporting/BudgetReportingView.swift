import SwiftUI

struct BudgetReportingView: View {
    let budget: BudgetDocument
    let currency: AppCurrency
    @Binding var isExpanded: Bool
    let scope: ReportingScope

    private var outflowComparisonSegments: [OutflowComparisonSegment] {
        let income = budget.categories(for: .income).total(\.amountPlanned)
        let expenses = budget.categories(for: .expenses)
        let savings = budget.categories(for: .savings)
        let debt = budget.categories(for: .debt)

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
                amount: expenses.total(\.amountPlanned),
                tint: Color(nsColor: .systemOrange)
            ),
            OutflowComparisonSegment(
                rowTitle: "Planned Allocation",
                componentTitle: "Savings",
                amount: savings.total(\.amountPlanned),
                tint: Color(nsColor: .systemGreen)
            ),
            OutflowComparisonSegment(
                rowTitle: "Planned Allocation",
                componentTitle: "Debt",
                amount: debt.total(\.amountPlanned),
                tint: Color(nsColor: .systemBlue)
            ),
            OutflowComparisonSegment(
                rowTitle: "Actual Allocation",
                componentTitle: "Expenses",
                amount: expenses.total(\.amountActual),
                tint: Color(nsColor: .systemOrange)
            ),
            OutflowComparisonSegment(
                rowTitle: "Actual Allocation",
                componentTitle: "Savings",
                amount: savings.total(\.amountActual),
                tint: Color(nsColor: .systemGreen)
            ),
            OutflowComparisonSegment(
                rowTitle: "Actual Allocation",
                componentTitle: "Debt",
                amount: debt.total(\.amountActual),
                tint: Color(nsColor: .systemBlue)
            )
        ]
    }

    private var outflowComparisonTotals: [OutflowComparisonTotal] {
        let income = budget.categories(for: .income).total(\.amountPlanned)
        let outflowTypes: [BudgetCategoryType] = [.expenses, .savings, .debt]
        let outflowCategories = outflowTypes.flatMap { budget.categories(for: $0) }

        return [
            OutflowComparisonTotal(title: "Income", amount: income),
            OutflowComparisonTotal(title: "Planned", amount: outflowCategories.total(\.amountPlanned)),
            OutflowComparisonTotal(title: "Actual", amount: outflowCategories.total(\.amountActual))
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
                        budget: budget,
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
    }

    private var inspectorChartStack: some View {
        VStack(alignment: .leading, spacing: 18) {
            incomeVsAllocationSection
            allocationBreakdownSection
        }
    }

    private var fullPageChartGrid: some View {
        GeometryReader { proxy in
            LazyVGrid(
                columns: chartGridColumns(for: proxy.size.width),
                alignment: .leading,
                spacing: 20
            ) {
                incomeVsAllocationSection
                allocationBreakdownSection

                CategoryBreakdownSection(
                    title: "Income Breakdown",
                    emptyTitle: "No income amounts yet",
                    currency: currency
                ) { mode in
                    categoryBreakdownSegments(for: .income, mode: mode)
                }

                CategoryBreakdownSection(
                    title: "Expenses Breakdown",
                    emptyTitle: "No expense amounts yet",
                    currency: currency
                ) { mode in
                    categoryBreakdownSegments(for: .expenses, mode: mode)
                }

                CategoryBreakdownSection(
                    title: "Savings Breakdown",
                    emptyTitle: "No savings amounts yet",
                    currency: currency
                ) { mode in
                    categoryBreakdownSegments(for: .savings, mode: mode)
                }

                CategoryBreakdownSection(
                    title: "Debt Breakdown",
                    emptyTitle: "No debt amounts yet",
                    currency: currency
                ) { mode in
                    categoryBreakdownSegments(for: .debt, mode: mode)
                }
            }
        }
    }

    private func chartGridColumns(for width: CGFloat) -> [GridItem] {
        let spacing: CGFloat = 20
        let minimumColumnWidth: CGFloat = 320
        let possibleColumnCount = Int((width + spacing) / (minimumColumnWidth + spacing))
        let columnCount = max(1, min(3, possibleColumnCount))

        return Array(
            repeating: GridItem(.flexible(minimum: minimumColumnWidth), spacing: spacing, alignment: .top),
            count: columnCount
        )
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
                amount: budget.categories(for: .expenses).total(mode.amountKeyPath),
                tint: Color(nsColor: .systemOrange)
            ),
            AllocationBreakdownSegment(
                title: "Savings",
                amount: budget.categories(for: .savings).total(mode.amountKeyPath),
                tint: Color(nsColor: .systemGreen)
            ),
            AllocationBreakdownSegment(
                title: "Debt",
                amount: budget.categories(for: .debt).total(mode.amountKeyPath),
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

        return budget.categories(for: type).enumerated().map { index, category in
            AllocationBreakdownSegment(
                title: category.title,
                amount: category[keyPath: mode.amountKeyPath],
                tint: colors[index % colors.count]
            )
        }
    }
}
