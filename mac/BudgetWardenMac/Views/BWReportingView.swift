/* 
 * Budget Warden
 * Copyright (c) 2026 Lazarov & Co EOOD
 * Author: Nikola Lazarov
 *
 * Licensed under the Source-Available Educational License. 
 * See the LICENSE file in the project root for full terms.
 */

import SwiftUI
import BWAppleCore

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
            ForEach(store.recentFiles, id: \.self) { url in
                Button {
                    Task { _ = await store.openBudget(at: url, windowStore: windowStore) }
                } label: {
                    if store.currentBudget?.url == url.path {
                        Label(store.currentBudget?.title ?? url.deletingPathExtension().lastPathComponent, systemImage: "checkmark")
                    }
                    else {
                        Text(url.deletingPathExtension().lastPathComponent)
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
        ScrollView {
            VStack(spacing: scope.chartSpacing) {
                BWReportingMetricGrid(
                    summary: summary,
                    currency: currency,
                    scope: scope
                )

                if scope == .inspector {
                    Divider()

                    if let amountModeControl {
                        amountModeControl
                    }

                    inspectorChartStack(summary)
                } else {
                    fullPageChartGrid(summary)
                }
            }
            .padding(scope == .inspector ? 12 : 20)
        }
    }

    private func inspectorChartStack(_ summary: BWReportingSummary) -> some View {
        VStack(alignment: .leading, spacing: scope.chartSpacing) {
            incomeVsAllocationSection(summary)
            allocationBreakdownSection(summary)
        }
    }

    private func fullPageChartGrid(_ summary: BWReportingSummary) -> some View {
        ViewThatFits(in: .horizontal) {
            chartGrid(columnCount: 3, summary: summary)
            chartGrid(columnCount: 2, summary: summary)
            chartGrid(columnCount: 1, summary: summary)
        }
    }

    private func chartGrid(
        columnCount: Int,
        summary: BWReportingSummary
    ) -> some View {
        let chartCount = 6
        let spacing = scope.chartSpacing
        let minimumColumnWidth: CGFloat = 320
        let minimumGridWidth = (CGFloat(columnCount) * minimumColumnWidth) + (CGFloat(columnCount - 1) * spacing)

        return Grid(alignment: .topLeading, horizontalSpacing: spacing, verticalSpacing: spacing) {
            ForEach(Array(stride(from: 0, to: chartCount, by: columnCount)), id: \.self) { rowStart in
                GridRow(alignment: .top) {
                    ForEach(rowStart..<min(rowStart + columnCount, chartCount), id: \.self) { index in
                        chartSection(at: index, summary: summary)
                            .frame(minWidth: minimumColumnWidth, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                }
            }
        }
        .frame(minWidth: minimumGridWidth, maxWidth: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func chartSection(
        at index: Int,
        summary: BWReportingSummary
    ) -> some View {
        switch index {
            case 0:
                incomeVsAllocationSection(summary)
            case 1:
                allocationBreakdownSection(summary)
            case 2:
                categoryBreakdownSection(
                    title: "Income Breakdown",
                    emptyTitle: "No \(amountMode.title.lowercased()) income amounts yet",
                    type: .income,
                    summary: summary
                )
            case 3:
                categoryBreakdownSection(
                    title: "Expenses Breakdown",
                    emptyTitle: "No \(amountMode.title.lowercased()) expense amounts yet",
                    type: .expenses,
                    summary: summary
                )
            case 4:
                categoryBreakdownSection(
                    title: "Savings Breakdown",
                    emptyTitle: "No \(amountMode.title.lowercased()) savings amounts yet",
                    type: .savings,
                    summary: summary
                )
            default:
                categoryBreakdownSection(
                    title: "Debt Breakdown",
                    emptyTitle: "No \(amountMode.title.lowercased()) debt amounts yet",
                    type: .debt,
                    summary: summary
                )
        }
    }

    private func incomeVsAllocationSection(
        _ summary: BWReportingSummary
    ) -> some View {
        BWIncomeVsAllocationChart(
            summary: summary,
            currency: currency,
            scope: scope
        )
    }

    private func allocationBreakdownSection(
        _ summary: BWReportingSummary
    ) -> some View {
        BWAllocationBreakdownChart(
            title: "\(amountMode.title) Allocation Breakdown",
            emptyTitle: "No \(amountMode.title.lowercased()) allocation amounts yet",
            segments: allocationBreakdownSegments(summary),
            currency: currency,
            scope: scope
        )
    }

    private func categoryBreakdownSection(
        title: String,
        emptyTitle: String,
        type: BWCategoryType,
        summary: BWReportingSummary
    ) -> some View {
        BWAllocationBreakdownChart(
            title: title,
            emptyTitle: emptyTitle,
            segments: categoryBreakdownSegments(for: type, summary: summary),
            currency: currency,
            scope: scope
        )
    }

    private func allocationBreakdownSegments(
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

    private func categoryBreakdownSegments(
        for type: BWCategoryType,
        summary: BWReportingSummary
    ) -> [BWReportingSegment] {
        summary.categorySegments(
            categoryType: type,
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
                return Color(nsColor: .systemOrange)
            case .savings:
                return Color(nsColor: .systemGreen)
            case .debt:
                return Color(nsColor: .systemBlue)
            case .income:
                return .primary
        }
    }
}
