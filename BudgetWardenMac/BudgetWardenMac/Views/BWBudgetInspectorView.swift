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
import BudgetWardenAppleCore

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
        let category = selectedCategory()

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
            .padding(.bottom)
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
    private func inspectorContent(category: BWCategory?) -> some View {
        if inspectorPanel == .reporting || category == nil {
            if let budget = store.currentBudget {
                BWBudgetReportingInspectorContent(budget: budget, currency: store.selectedCurrency)
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
                canMoveUp: store.canMoveCategory(category, by: -1),
                canMoveDown: store.canMoveCategory(category, by: 1),
                moveUp: {
                    Task(priority: .userInitiated) {
                        await store.moveCategory(category, by: -1, windowStore: windowStore)
                    }
                },
                moveDown: {
                    Task(priority: .userInitiated) {
                        await store.moveCategory(category, by: 1, windowStore: windowStore)
                    }
                },
                deleteCategory: {
                    deleteCategory(category)
                },
                saveCategory: { updatedCategory in
                    Task(priority: .userInitiated) {
                        await store.updateCategory(
                            updatedCategory,
                            windowStore: windowStore
                        )
                    }
                }
            )
        }
    }

    private func selectedCategory() -> BWCategory? {
        guard
            let selection,
            let categoryID = UUID(uuidString: selection),
            let selectedCategory = store.currentBudget?.categories.first(where: { $0.id == categoryID })
        else {
            return nil
        }

        return selectedCategory
    }
}

private struct BWCategoryInspectorView: View {
    @Environment(\.openWindow) private var openWindow

    let category: BWCategory

    let budgetID: UUID
    let canMoveUp: Bool
    let canMoveDown: Bool
    let moveUp: () -> Void
    let moveDown: () -> Void
    let deleteCategory: () -> Void
    let saveCategory: (BWCategory) -> Void

    @State private var draftCategory: BWCategory
    @State private var accumulatedAmountText = ""
    @State private var plannedAmountText = ""
    @State private var isDeleteConfirmationPresented = false
    @State private var pendingSaveTask: Task<Void, Never>?
    @FocusState private var focusedField: Field?

    init(
        category: BWCategory,
        budgetID: UUID,
        canMoveUp: Bool,
        canMoveDown: Bool,
        moveUp: @escaping () -> Void,
        moveDown: @escaping () -> Void,
        deleteCategory: @escaping () -> Void,
        saveCategory: @escaping (BWCategory) -> Void
    ) {
        self.category = category
        self.budgetID = budgetID
        self.canMoveUp = canMoveUp
        self.canMoveDown = canMoveDown
        self.moveUp = moveUp
        self.moveDown = moveDown
        self.deleteCategory = deleteCategory
        self.saveCategory = saveCategory
        _draftCategory = State(initialValue: category)
    }

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
        switch draftCategory.categoryType {
            case .income, .expenses:
                return false
            case .savings, .debt:
                return true
        }
    }

    var body: some View {
        VStack {
            Form {
                TextField("Title", text: $draftCategory.title)
                    .accessibilityIdentifier("categoryInspectorTitleTextField")
                    .focused($focusedField, equals: .title)
                    .onSubmit {
                        saveNow()
                    }
                    .onChange(of: draftCategory.title) { _, _ in
                        guard draftCategory.title != category.title else {
                            return
                        }

                        scheduleSave()
                    }

                Picker("Type", selection: $draftCategory.categoryType) {
                    ForEach(BWCategoryType.allCases, id: \.self) { categoryType in
                        Text(categoryType.title)
                            .tag(categoryType)
                    }
                }
                .onChange(of: draftCategory.categoryType) { _, _ in
                    guard draftCategory.categoryType != category.categoryType else {
                        return
                    }

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
                        .accessibilityIdentifier("categoryInspectorAccumulatedTextField")
                        .foregroundStyle(parsedAccumulatedAmount == nil ? .red : .primary)
                        .focused($focusedField, equals: .accumulated)
                        .monospacedDigit()
                        .onSubmit {
                            saveNow()
                        }
                        .onChange(of: accumulatedAmountText) { _, newValue in
                            if let amount = UInt64.parseMoneyAmount(newValue, emptyValue: 0) {
                                guard draftCategory.amountAccumulated != amount else {
                                    return
                                }

                                draftCategory.amountAccumulated = amount
                                scheduleSave()
                            }
                        }
                }

                TextField("Planned", text: $plannedAmountText, prompt: Text("0.00"))
                    .accessibilityIdentifier("categoryInspectorPlannedTextField")
                    .foregroundStyle(parsedPlannedAmount == nil ? .red : .primary)
                    .focused($focusedField, equals: .planned)
                    .monospacedDigit()
                    .onSubmit {
                        saveNow()
                    }
                    .onChange(of: plannedAmountText) { _, newValue in
                        if let amount = UInt64.parseMoneyAmount(newValue, emptyValue: 0) {
                            guard draftCategory.amountPlanned != amount else {
                                return
                            }

                            draftCategory.amountPlanned = amount
                            scheduleSave()
                        }
                    }

                LabeledContent("Actual") {
                    Text(draftCategory.amountActual.moneyInputText)
                        .accessibilityIdentifier("categoryInspectorActualValue")
                        .monospacedDigit()
                }
                
                if !draftCategory.transactions.isEmpty {
                    Button {
                        openWindow(
                            id: "window-category-transactions",
                            value: BWCategoryTransactionsWindowValue(
                                budgetID: budgetID,
                                categoryID: draftCategory.id
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
                .accessibilityIdentifier("categoryInspectorDeleteButton")
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
            draftCategory = category
            resetAmountFields()
        }
        .onChange(of: category.title) { _, newValue in
            guard focusedField != .title else {
                return
            }

            draftCategory.title = newValue
        }
        .onDisappear {
            saveNow()
        }
        .confirmationDialog(
            "Delete \(draftCategory.title)?",
            isPresented: $isDeleteConfirmationPresented
        ) {
            Button("Delete Category", role: .destructive) {
                saveNow()
                deleteCategory()
            }
            .accessibilityIdentifier("categoryInspectorDeleteConfirmButton")

            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will remove the category and its transactions from the budget.")
        }
    }

    private func resetAmountFields() {
        accumulatedAmountText = draftCategory.amountAccumulated.moneyInputText
        plannedAmountText = draftCategory.amountPlanned.moneyInputText
    }

    private func scheduleSave() {
        pendingSaveTask?.cancel()

        let categoryToSave = draftCategory

        pendingSaveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))

            guard !Task.isCancelled else {
                return
            }

            saveCategory(categoryToSave)
        }
    }

    private func saveNow() {
        pendingSaveTask?.cancel()
        pendingSaveTask = nil

        guard parsedAccumulatedAmount != nil,
              parsedPlannedAmount != nil
        else {
            return
        }

        saveCategory(draftCategory)
    }
}
