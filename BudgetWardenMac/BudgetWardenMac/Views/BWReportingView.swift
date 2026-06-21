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
import AppleCore

struct BWReportingView: View {
    @ObservedObject var store: BWStore
    @ObservedObject var windowStore: BWWindowStore

    @State private var amountMode: BWReportingAmountMode = .planned

    var body: some View {
        Group {
            if let budget = store.currentBudget {
                BWBudgetReportingContent(
                    budget: budget,
                    currency: store.selectedCurrency,
                    amountMode: amountMode,
                    scope: .fullPage
                )
            }
            else {
                ContentUnavailableView(
                    "No Budget Selected",
                    systemImage: "x.circle"
                )
            }
        }
        .navigationTitle("Reporting")
        .toolbar {
            ToolbarItemGroup(placement: .principal) {
                budgetMenu
            }

            ToolbarItemGroup(placement: .primaryAction) {
                Picker("Reporting Amount", selection: $amountMode) {
                    ForEach(BWReportingAmountMode.allCases) { mode in
                        Text(mode.title)
                            .tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .help("Switch all reporting breakdowns between planned and actual amounts")
            }
        }
    }

    private var budgetMenu: some View {
        Menu {
            ForEach(store.budgetsInVault) { budget in
                Button {
                    store.selectBudget(budget)
                } label: {
                    if store.currentBudget?.id == budget.id {
                        Label(budget.title, systemImage: "checkmark")
                    }
                    else {
                        Text(budget.title)
                    }
                }
            }

            Divider()

            Button {
                windowStore.openBudgetDialog()
            } label: {
                Label("New Budget", systemImage: "plus")
            }
        } label: {
            Text(store.currentBudget?.title ?? "Budget")
        }
    }
}

struct BWBudgetReportingInspectorContent: View {
    let budget: BWBudget
    let currency: BWCurrency

    @State private var amountMode: BWReportingAmountMode = .planned

    var body: some View {
        BWBudgetReportingContent(
            budget: budget,
            currency: currency,
            amountMode: amountMode,
            scope: .inspector,
            amountModeControl: AnyView(amountModePicker)
        )
    }

    private var amountModePicker: some View {
        Picker("Reporting Amount", selection: $amountMode) {
            ForEach(BWReportingAmountMode.allCases) { mode in
                Text(mode.title)
                    .tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .controlSize(.large)
        .labelsHidden()
    }
}

struct BWBudgetReportingContent: View {
    let budget: BWBudget
    let currency: BWCurrency
    let amountMode: BWReportingAmountMode
    let scope: BWReportingScope
    let amountModeControl: AnyView?

    init(
        budget: BWBudget,
        currency: BWCurrency,
        amountMode: BWReportingAmountMode,
        scope: BWReportingScope,
        amountModeControl: AnyView? = nil
    ) {
        self.budget = budget
        self.currency = currency
        self.amountMode = amountMode
        self.scope = scope
        self.amountModeControl = amountModeControl
    }

    var body: some View {
        ScrollView {
            VStack(spacing: scope.chartSpacing) {
                BWReportingMetricGrid(
                    budget: budget,
                    currency: currency,
                    scope: scope
                )

                if scope == .inspector {
                    Divider()
                    
                    if let amountModeControl {
                        amountModeControl
                    }

                    inspectorChartStack
                }
                else {
                    fullPageChartGrid
                }
            }
            .padding(scope == .inspector ? 12 : 20)
        }
    }

    private var inspectorChartStack: some View {
        VStack(alignment: .leading, spacing: scope.chartSpacing) {
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
        let spacing = scope.chartSpacing
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
                categoryBreakdownSection(
                    title: "Income Breakdown",
                    emptyTitle: "No \(amountMode.title.lowercased()) income amounts yet",
                    type: .income
                )
            case 3:
                categoryBreakdownSection(
                    title: "Expenses Breakdown",
                    emptyTitle: "No \(amountMode.title.lowercased()) expense amounts yet",
                    type: .expenses
                )
            case 4:
                categoryBreakdownSection(
                    title: "Savings Breakdown",
                    emptyTitle: "No \(amountMode.title.lowercased()) savings amounts yet",
                    type: .savings
                )
            default:
                categoryBreakdownSection(
                    title: "Debt Breakdown",
                    emptyTitle: "No \(amountMode.title.lowercased()) debt amounts yet",
                    type: .debt
                )
        }
    }

    private var incomeVsAllocationSection: some View {
        BWIncomeVsAllocationChart(
            budget: budget,
            currency: currency,
            scope: scope
        )
    }

    private var allocationBreakdownSection: some View {
        BWAllocationBreakdownChart(
            title: "\(amountMode.title) Allocation Breakdown",
            emptyTitle: "No \(amountMode.title.lowercased()) allocation amounts yet",
            segments: allocationBreakdownSegments,
            currency: currency,
            scope: scope
        )
    }

    private func categoryBreakdownSection(
        title: String,
        emptyTitle: String,
        type: BWCategoryType
    ) -> some View {
        BWAllocationBreakdownChart(
            title: title,
            emptyTitle: emptyTitle,
            segments: categoryBreakdownSegments(for: type),
            currency: currency,
            scope: scope
        )
    }

    private var allocationBreakdownSegments: [BWReportingSegment] {
        [
            BWReportingSegment(
                title: "Expenses",
                amount: total(for: [.expenses], amount: amountMode.amountKeyPath),
                tint: Color(nsColor: .systemOrange)
            ),
            BWReportingSegment(
                title: "Savings",
                amount: total(for: [.savings], amount: amountMode.amountKeyPath),
                tint: Color(nsColor: .systemGreen)
            ),
            BWReportingSegment(
                title: "Debt",
                amount: total(for: [.debt], amount: amountMode.amountKeyPath),
                tint: Color(nsColor: .systemBlue)
            )
        ].filter { $0.amount > 0 }
    }

    private func categoryBreakdownSegments(for type: BWCategoryType) -> [BWReportingSegment] {
        budget.categories
            .filter { $0.categoryType == type && $0[keyPath: amountMode.amountKeyPath] > 0 }
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
