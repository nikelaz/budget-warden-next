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

enum BWBudgetInspectorPanel: Hashable {
    case reporting
    case inspector
}

struct BWBudgetInspectorView: View {
    @ObservedObject var store: BWStore
    @ObservedObject var windowStore: BWWindowStore

    @Binding var selection: BWCategoryTableRow.ID?
    @Binding var inspectorPanel: BWBudgetInspectorPanel

    let deleteCategory: (BWCategory) -> Void

    var body: some View {
        let category = selectedCategoryBinding()

        VStack(spacing: 0) {
            Picker("Inspector Panel", selection: $inspectorPanel) {
                Image(systemName: "chart.pie")
                    .tag(BWBudgetInspectorPanel.reporting)
                    .help("Reporting")

                Image(systemName: "slider.horizontal.3")
                    .tag(BWBudgetInspectorPanel.inspector)
                    .help("Inspector")
                    .selectionDisabled(selection == nil)
            }
            .pickerStyle(.segmented)
            .controlSize(.extraLarge)
            .labelsHidden()
            .disabled(store.currentBudget == nil)
            .onChange(of: inspectorPanel) { _, newValue in
                if newValue == .inspector && category == nil {
                    inspectorPanel = .reporting
                }
            }
            .frame(maxWidth: .infinity)

            inspectorContent(category: category)
        }
    }

    @ViewBuilder
    private func inspectorContent(category: Binding<BWCategory>?) -> some View {
        if inspectorPanel == .reporting || category == nil {
            if let budget = store.currentBudget {
                BWBudgetReportingInspectorView(budget: budget, currency: store.selectedCurrency)
            }
            else {
                ContentUnavailableView(
                    "No Budget",
                    systemImage: "doc"
                )
            }
        }
        else if let category, let budgetID = store.currentBudget?.id {
            BWCategoryInspectorView(
                category: category,
                budgetID: budgetID,
                canMoveUp: store.canMoveCategory(category.wrappedValue, by: -1),
                canMoveDown: store.canMoveCategory(category.wrappedValue, by: 1),
                moveUp: {
                    store.moveCategory(category.wrappedValue, by: -1, windowStore: windowStore)
                },
                moveDown: {
                    store.moveCategory(category.wrappedValue, by: 1, windowStore: windowStore)
                },
                deleteCategory: {
                    deleteCategory(category.wrappedValue)
                }
            ) {
                Task {
                    await store.saveCurrentBudgetNow(
                        budgetID: budgetID,
                        windowStore: windowStore
                    )
                }
            }
        }
    }

    private func selectedCategoryBinding() -> Binding<BWCategory>? {
        guard
            let selection,
            let categoryID = UUID(uuidString: selection),
            let selectedCategory = store.currentBudget?.categories.first(where: { $0.id == categoryID })
        else {
            return nil
        }

        return Binding(
            get: {
                store.currentBudget?.categories.first { $0.id == categoryID } ?? selectedCategory
            },
            set: { updatedCategory in
                store.updateCategory(
                    updatedCategory,
                    windowStore: windowStore
                )
            }
        )
    }
}

private enum BWBudgetReportingAmountMode: String, CaseIterable, Identifiable {
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
}

private struct BWBudgetReportingInspectorView: View {
    let budget: BWBudget
    let currency: BWCurrency

    @State private var allocationMode: BWBudgetReportingAmountMode = .planned

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

    private var allocationSegments: [BWBudgetReportingSegment] {
        [
            BWBudgetReportingSegment(
                title: "Income",
                amount: incomeTotal,
                tint: Color(nsColor: .systemGreen)
            ),
            BWBudgetReportingSegment(
                title: "Spending",
                amount: plannedSpendingTotal,
                tint: Color(nsColor: .systemRed)
            ),
            BWBudgetReportingSegment(
                title: "Savings",
                amount: plannedSavingsTotal,
                tint: Color(nsColor: .systemBlue)
            )
        ].filter { $0.amount > 0 }
    }

    private var breakdownSegments: [BWBudgetReportingSegment] {
        let amountKeyPath: KeyPath<BWCategory, UInt64> = allocationMode == .planned
            ? \.amountPlanned
            : \.amountActual

        return budget.categories
            .filter { $0.categoryType != .income && $0[keyPath: amountKeyPath] > 0 }
            .enumerated()
            .map { index, category in
                BWBudgetReportingSegment(
                    title: category.title,
                    amount: category[keyPath: amountKeyPath],
                    tint: BWBudgetReportingSegment.palette[index % BWBudgetReportingSegment.palette.count]
                )
            }
    }

    private var breakdownTotal: UInt64 {
        breakdownSegments.reduce(0) { $0 + $1.amount }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                metricGrid
                incomeVsAllocationSection
                allocationBreakdownSection
            }
            .padding(12)
        }
    }

    private var metricGrid: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 130), spacing: 10, alignment: .topLeading)],
            alignment: .leading,
            spacing: 10
        ) {
            BWBudgetReportingMetricView(title: "Income", value: incomeTotal, currency: currency)
            BWBudgetReportingMetricView(title: "Planned Spending", value: plannedSpendingTotal, currency: currency)
            BWBudgetReportingMetricView(title: "Actual Spending", value: actualSpendingTotal, currency: currency)
            BWBudgetReportingMetricView(title: "Savings", value: plannedSavingsTotal, currency: currency)
            BWBudgetReportingMetricView(
                title: "Left to Budget",
                signedValue: leftToBudgetTotal,
                valueColor: leftToBudgetTotal < 0 ? Color(nsColor: .systemRed) : .primary,
                currency: currency
            )
        }
    }

    private var incomeVsAllocationSection: some View {
        BWBudgetReportingSection(title: "Income vs Allocation") {
            if allocationSegments.isEmpty {
                BWBudgetReportingEmptyView(title: "No allocation amounts yet")
            }
            else {
                Chart(allocationSegments) { segment in
                    BarMark(
                        x: .value("Amount", chartAmount(segment.amount)),
                        y: .value("Category", segment.title)
                    )
                    .foregroundStyle(segment.tint)
                }
                .chartLegend(.hidden)
                .frame(height: 130)

                VStack(alignment: .leading, spacing: 6) {
                    ForEach(allocationSegments) { segment in
                        BWBudgetReportingLegendRow(segment: segment, total: incomeTotal, currency: currency)
                    }
                }
            }
        }
    }

    private var allocationBreakdownSection: some View {
        BWBudgetReportingSection(title: "Allocation Breakdown") {
            Picker("Breakdown", selection: $allocationMode) {
                ForEach(BWBudgetReportingAmountMode.allCases) { mode in
                    Text(mode.title)
                        .tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if breakdownTotal == 0 {
                BWBudgetReportingEmptyView(title: "No \(allocationMode.title.lowercased()) amounts yet")
            }
            else {
                Chart(breakdownSegments) { segment in
                    SectorMark(
                        angle: .value("Amount", chartAmount(segment.amount)),
                        innerRadius: .ratio(0.58),
                        angularInset: 1.5
                    )
                    .foregroundStyle(segment.tint)
                }
                .chartLegend(.hidden)
                .frame(height: 170)

                VStack(alignment: .leading, spacing: 6) {
                    ForEach(breakdownSegments) { segment in
                        BWBudgetReportingLegendRow(segment: segment, total: breakdownTotal, currency: currency)
                    }
                }
            }
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

    private func chartAmount(_ amount: UInt64) -> Double {
        Double(amount) / 100
    }
}

private struct BWBudgetReportingSegment: Identifiable {
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

private struct BWBudgetReportingMetricView: View {
    let title: String
    let valueText: String
    var valueColor: Color = .primary
    let currency: BWCurrency

    init(title: String, value: UInt64, valueColor: Color = .primary, currency: BWCurrency) {
        self.title = title
        self.valueText = value.formattedMoneyAmount(currency: currency)
        self.valueColor = valueColor
        self.currency = currency
    }

    init(title: String, signedValue: Int64, valueColor: Color = .primary, currency: BWCurrency) {
        self.title = title
        let prefix = signedValue < 0 ? "-" : ""
        self.valueText = "\(prefix)\(UInt64(signedValue.magnitude).formattedMoneyAmount(currency: currency))"
        self.valueColor = valueColor
        self.currency = currency
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

private struct BWBudgetReportingSection<Content: View>: View {
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
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(Color(nsColor: .quaternarySystemFill))
            .clipShape(.rect(cornerRadius: 8, style: .continuous))
        }
    }
}

private struct BWBudgetReportingLegendRow: View {
    let segment: BWBudgetReportingSegment
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

private struct BWBudgetReportingEmptyView: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 130)
    }
}

private struct BWCategoryInspectorView: View {
    @Environment(\.openWindow) private var openWindow

    @Binding var category: BWCategory

    let budgetID: UUID
    let canMoveUp: Bool
    let canMoveDown: Bool
    let moveUp: () -> Void
    let moveDown: () -> Void
    let deleteCategory: () -> Void
    let saveNow: () -> Void

    @State private var accumulatedAmountText = ""
    @State private var plannedAmountText = ""
    @State private var isDeleteConfirmationPresented = false
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case title
        case accumulated
        case planned
    }

    private var parsedAccumulatedAmount: UInt64? {
        UInt64.parseMoneyAmount(accumulatedAmountText, emptyValue: 0)
    }

    private var parsedPlannedAmount: UInt64? {
        UInt64.parseMoneyAmount(plannedAmountText, emptyValue: 0)
    }

    private var showsAccumulatedAmount: Bool {
        switch category.categoryType {
            case .income, .expenses:
                return false
            case .savings, .debt:
                return true
        }
    }

    var body: some View {
        VStack {
            Form {
                TextField("Title", text: $category.title)
                    .focused($focusedField, equals: .title)
                    .onSubmit {
                        saveNow()
                    }

                Picker("Type", selection: $category.categoryType) {
                    ForEach(BWCategoryType.allCases, id: \.self) { categoryType in
                        Text(categoryType.title)
                            .tag(categoryType)
                    }
                }
                .onChange(of: category.categoryType) { _, _ in
                    saveNow()
                }

                LabeledContent("Order") {
                    HStack(spacing: 8) {
                        Button {
                            saveNow()
                            moveUp()
                        } label: {
                            Image(systemName: "chevron.up")
                        }
                        .disabled(!canMoveUp)
                        .help("Move Up")

                        Button {
                            saveNow()
                            moveDown()
                        } label: {
                            Image(systemName: "chevron.down")
                        }
                        .disabled(!canMoveDown)
                        .help("Move Down")
                    }
                }

                if showsAccumulatedAmount {
                    TextField("Accumulated", text: $accumulatedAmountText, prompt: Text("0.00"))
                        .foregroundStyle(parsedAccumulatedAmount == nil ? .red : .primary)
                        .focused($focusedField, equals: .accumulated)
                        .monospacedDigit()
                        .onSubmit {
                            saveNow()
                        }
                        .onChange(of: accumulatedAmountText) { _, newValue in
                            if let amount = UInt64.parseMoneyAmount(newValue, emptyValue: 0) {
                                category.amountAccumulated = amount
                            }
                        }
                }

                TextField("Planned", text: $plannedAmountText, prompt: Text("0.00"))
                    .foregroundStyle(parsedPlannedAmount == nil ? .red : .primary)
                    .focused($focusedField, equals: .planned)
                    .monospacedDigit()
                    .onSubmit {
                        saveNow()
                    }
                    .onChange(of: plannedAmountText) { _, newValue in
                        if let amount = UInt64.parseMoneyAmount(newValue, emptyValue: 0) {
                            category.amountPlanned = amount
                        }
                    }

                LabeledContent("Actual") {
                    Text(category.amountActual.moneyInputText)
                        .monospacedDigit()
                }
                
                if !category.transactions.isEmpty {
                    Button {
                        openWindow(
                            id: "window-category-transactions",
                            value: BWCategoryTransactionsWindowValue(
                                budgetID: budgetID,
                                categoryID: category.id
                            )
                        )
                    } label: {
                        Label("View Transactions", systemImage: "list.bullet.rectangle")
                    }
                }

                Button(role: .destructive) {
                    isDeleteConfirmationPresented = true
                } label: {
                    Label("Delete Category", systemImage: "trash")
                }
            }
        }
        .onAppear {
            resetAmountFields()
        }
        .onChange(of: focusedField) { oldValue, _ in
            if oldValue != nil {
                saveNow()
            }
        }
        .onChange(of: category.id) { _, _ in
            saveNow()
            resetAmountFields()
        }
        .onDisappear {
            saveNow()
        }
        .confirmationDialog(
            "Delete \(category.title)?",
            isPresented: $isDeleteConfirmationPresented
        ) {
            Button("Delete Category", role: .destructive) {
                saveNow()
                deleteCategory()
            }

            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will remove the category and its transactions from the budget.")
        }
    }

    private func resetAmountFields() {
        accumulatedAmountText = category.amountAccumulated.moneyInputText
        plannedAmountText = category.amountPlanned.moneyInputText
    }
}
