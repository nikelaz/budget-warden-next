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
    private func inspectorContent(category: Binding<BWCategory>?) -> some View {
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
                    .accessibilityIdentifier("categoryInspectorTitleTextField")
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
                        .accessibilityIdentifier("categoryInspectorAccumulatedTextField")
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
                    .accessibilityIdentifier("categoryInspectorPlannedTextField")
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
                        .accessibilityIdentifier("categoryInspectorActualValue")
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
            .accessibilityIdentifier("categoryInspectorDeleteConfirmButton")

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
