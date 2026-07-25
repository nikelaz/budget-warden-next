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

enum BWCategoryTableRowType {
    case regular
    case footer
}

struct BWCategoryTableRow: Identifiable {
    let id: String
    let type: BWCategoryTableRowType
    let categoryType: BWCategoryType
    let category: BWCategory?
}

struct BudgetView: View {
    @ObservedObject var store: BWStore
    @ObservedObject var windowStore: BWWindowStore

    @State private var selection: BWCategoryTableRow.ID?
    
    @State var newTitle = ""
    @State var isCreatingIncomeDialogOpen: Bool = false
    @State var isCreatingExpenseDialogOpen: Bool = false
    @State var isCreatingSavingsDialogOpen: Bool = false
    @State var isCreatingDebtDialogOpen: Bool = false
    @State var isCreatingCategoryDialogOpen: Bool = false
    @State var isCreatingTransactionDialogOpen: Bool = false
    @State var isInspectorPresented: Bool = true
    @State private var inspectorPanel: BWBudgetInspectorPanel = .reporting
    @State private var categoryPendingDeletion: BWCategory?

    private func openCreateCategoryDialog() {
        isCreatingCategoryDialogOpen = true
    }

    private func openCreateTransactionDialog() {
        isCreatingTransactionDialogOpen = true
    }

    private func openCreateIncomeCategoryDialog() {
        isCreatingIncomeDialogOpen = true
    }

    private func openCreateExpenseCategoryDialog() {
        isCreatingExpenseDialogOpen = true
    }

    private func openCreateSavingsCategoryDialog() {
        isCreatingSavingsDialogOpen = true
    }

    private func openCreateDebtCategoryDialog() {
        isCreatingDebtDialogOpen = true
    }

    private func closeCreateIncomeCategoryDialog() {
        isCreatingIncomeDialogOpen = false 
    }

    private func closeCreateExpenseCategoryDialog() {
        isCreatingExpenseDialogOpen = false
    }

    private func closeCreateSavingsCategoryDialog() {
        isCreatingSavingsDialogOpen = false 
    }

    private func closeCreateDebtCategoryDialog() {
        isCreatingDebtDialogOpen = false 
    }

    private func closeCreateCategoryDialog() {
        isCreatingCategoryDialogOpen = false
    }

    private func closeCreateTransactionDialog() {
        isCreatingTransactionDialogOpen = false
    }

    private func promptDeleteCategory(_ category: BWCategory) {
        categoryPendingDeletion = category
    }

    private func deleteCategory(_ category: BWCategory) {
        Task(priority: .userInitiated) {
            await store.deleteCategory(category, windowStore: windowStore)

            if selection == category.id.uuidString {
                selection = nil
            }
        }
    }

    @ViewBuilder
    private func deleteCategoryContextMenuButton(_ category: BWCategory) -> some View {
        Button(role: .destructive) {
            promptDeleteCategory(category)
        } label: {
            Label("Delete Category", systemImage: "trash")
        }
        .accessibilityIdentifier("categoryContextMenuDeleteButton")
    }
    
    private func fromTypeToCreateLabel(categoryType: BWCategoryType) -> String {
        switch categoryType {
            case .income:
                return "New Income"
            case .expenses:
                return "New Category"
            case .savings:
                return "New Fund"
            case .debt:
                return "New Debt"
        }
    }

    private func showsAccumulatedAmount(for categoryType: BWCategoryType) -> Bool {
        switch categoryType {
            case .income, .expenses:
                return false
            case .savings, .debt:
                return true
        }
    }

    private func sectionTotal(
        categoryType: BWCategoryType,
        amount: (BWCategory) -> BWMoneyAmount
    ) -> UInt64? {
        guard let budget = store.currentBudget else {
            return 0
        }

        return UInt64.sumMoneyAmounts(
            budget.categories
                .filter { $0.categoryType == categoryType }
                .map { amount($0).unsignedValue }
        )
    }

    private func formattedSectionTotal(
        categoryType: BWCategoryType,
        amount: (BWCategory) -> BWMoneyAmount
    ) -> String {
        guard let total = sectionTotal(categoryType: categoryType, amount: amount) else {
            return "Too large"
        }

        return total.formattedMoneyAmount(currency: store.selectedCurrency)
    }

    private func orderedCategories(for categoryType: BWCategoryType) -> [BWCategory] {
        guard let budget = store.currentBudget else {
            return []
        }

        return budget.orderedCategories(for: categoryType)
    }

    private var hasCategories: Bool {
        store.currentBudget?.categories.isEmpty == false
    }

    var body: some View {
        Table(of: BWCategoryTableRow.self, selection: $selection) {
            TableColumn("Category") { tableRow in
                switch tableRow.type {
                    case .regular:
                        Text(tableRow.category!.title)
                            .accessibilityIdentifier("budgetCategoryTitle_\(tableRow.category!.title)")
                    case .footer:
                        Button {
                            switch tableRow.categoryType {
                                case .income:
                                    openCreateIncomeCategoryDialog()
                                case .expenses:
                                    openCreateExpenseCategoryDialog()
                                case .savings:
                                    openCreateSavingsCategoryDialog()
                                case .debt:
                                    openCreateDebtCategoryDialog()
                            }
                        } label: {
                            Label(
                                fromTypeToCreateLabel(categoryType: tableRow.categoryType),
                                systemImage: "plus.circle"
                            )
                            .foregroundColor(.accentColor)
                        }
                        .accessibilityIdentifier("create\(tableRow.categoryType.toString())CategoryFooterButton")
                }
            }

            TableColumn("Accumulated") { tableRow in
                switch tableRow.type {
                    case .regular:                
                        if showsAccumulatedAmount(for: tableRow.categoryType) {
                            Text(tableRow.category!.amountAccumulated.formattedMoneyAmount(
                                currency: store.selectedCurrency
                            ))
                            .accessibilityIdentifier("budgetCategoryAccumulated_\(tableRow.category!.title)")
                            .accessibilityValue(tableRow.category!.amountAccumulated.moneyInputText)
                        }
                        else {
                            Text("")
                        }
                    case .footer:
                        if showsAccumulatedAmount(for: tableRow.categoryType) {
                            Text(formattedSectionTotal(
                                categoryType: tableRow.categoryType,
                                amount: \.amountAccumulated
                            ))
                            .fontWeight(.semibold)
                        }
                        else {
                            Text("")
                        }
                }
            }
            
            TableColumn("Planned") { tableRow in
                switch tableRow.type {
                    case .regular:
                        Text(tableRow.category!.amountPlanned.formattedMoneyAmount(currency: store.selectedCurrency))
                            .accessibilityIdentifier("budgetCategoryPlanned_\(tableRow.category!.title)")
                            .accessibilityValue(tableRow.category!.amountPlanned.moneyInputText)
                    case .footer:
                        Text(formattedSectionTotal(
                            categoryType: tableRow.categoryType,
                            amount: \.amountPlanned
                        ))
                        .fontWeight(.semibold)
                }
            }
            
            TableColumn("Actual") { tableRow in
                switch tableRow.type {
                    case .regular:
                        Text(tableRow.category!.amountActual.formattedMoneyAmount(currency: store.selectedCurrency))
                            .accessibilityIdentifier("budgetCategoryActual_\(tableRow.category!.title)")
                            .accessibilityValue(tableRow.category!.amountActual.moneyInputText)
                    case .footer:
                        Text(formattedSectionTotal(
                            categoryType: tableRow.categoryType,
                            amount: \.amountActual
                        ))
                        .fontWeight(.semibold)
                }
            }
        } rows: {
            Section("Income") {
                ForEach(orderedCategories(for: .income)) { category in
                    TableRow(BWCategoryTableRow(
                        id: category.id.uuidString,
                        type: .regular,
                        categoryType: category.categoryType,
                        category: category
                    ))
                    .contextMenu {
                        deleteCategoryContextMenuButton(category)
                    }
                }
                
                TableRow(BWCategoryTableRow(
                    id: "footer-income",
                    type: .footer,
                    categoryType: .income,
                    category: nil
                ))
                .selectionDisabled()
            }

            Section("Expenses") {
                ForEach(orderedCategories(for: .expenses)) { category in
                    TableRow(BWCategoryTableRow(
                        id: category.id.uuidString,
                        type: .regular,
                        categoryType: category.categoryType,
                        category: category
                    ))
                    .contextMenu {
                        deleteCategoryContextMenuButton(category)
                    }
                }
                
                TableRow(BWCategoryTableRow(
                    id: "footer-expenses",
                    type: .footer,
                    categoryType: .expenses,
                    category: nil
                ))
                .selectionDisabled()
            }

            Section("Savings") {
                ForEach(orderedCategories(for: .savings)) { category in
                    TableRow(BWCategoryTableRow(
                        id: category.id.uuidString,
                        type: .regular,
                        categoryType: category.categoryType,
                        category: category
                    ))
                    .contextMenu {
                        deleteCategoryContextMenuButton(category)
                    }
                }
                
                TableRow(BWCategoryTableRow(
                    id: "footer-savings",
                    type: .footer,
                    categoryType: .savings,
                    category: nil
                ))
                .selectionDisabled()
            }

            Section("Debt") {
                ForEach(orderedCategories(for: .debt)) { category in
                    TableRow(BWCategoryTableRow(
                        id: category.id.uuidString,
                        type: .regular,
                        categoryType: category.categoryType,
                        category: category
                    ))
                    .contextMenu {
                        deleteCategoryContextMenuButton(category)
                    }
                }
                
                TableRow(BWCategoryTableRow(
                    id: "footer-debt",
                    type: .footer,
                    categoryType: .debt,
                    category: nil
                ))
                .selectionDisabled()
            }
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .navigationTitle("Budget")
        .toolbar {
            ToolbarItemGroup(placement: .principal) {
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
                .accessibilityIdentifier("budgetSwitcherMenu")
                
                Menu {
                    Button {
                        windowStore.openBudgetDialog()
                    } label: {
                        Label("Budget", systemImage: "rectangle.stack.badge.plus")
                    }

                    Button {
                        openCreateCategoryDialog()
                    } label: {
                        Label("Category", systemImage: "folder.badge.plus")
                    }

                    Button {
                        openCreateTransactionDialog()
                    } label: {
                        Label("Transaction", systemImage: "receipt")
                    }
                    .disabled(!hasCategories)
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add")
                .accessibilityIdentifier("addToolbarMenu")
                .help("Add")
            }
          
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    isInspectorPresented = !isInspectorPresented
                } label: {
                    Image(systemName: "sidebar.right")
                }
            }
        }
        .onChange(of: selection) { _, newValue in
            if newValue?.hasPrefix("footer-") == true {
                selection = nil
            }

            inspectorPanel = selection == nil ? .reporting : .inspector
        }
        .onChange(of: store.currentBudget?.id) { _, _ in
            selection = nil
            inspectorPanel = .reporting
        }
        .inspector(
            isPresented: $isInspectorPresented,
            content: {
                BWBudgetInspectorView(
                    store: store,
                    windowStore: windowStore,
                    selection: $selection,
                    inspectorPanel: $inspectorPanel,
                    deleteCategory: deleteCategory
                )
                .inspectorColumnWidth(min: 280, ideal: 320, max: 480)
            }
        )
        .sheet(isPresented: $isCreatingIncomeDialogOpen) {
            CreateCategoryView(
                type: .income,
                hint: "Salary",
                onClose: closeCreateIncomeCategoryDialog
            )
            .frame(minWidth: 280)
        }
        .sheet(isPresented: $isCreatingExpenseDialogOpen) {
            CreateCategoryView(
                type: .expenses,
                hint: "Groceries",
                onClose: closeCreateExpenseCategoryDialog 
            )
            .frame(minWidth: 280)
        }
        .sheet(isPresented: $isCreatingSavingsDialogOpen) {
            CreateCategoryView(
                type: .savings,
                hint: "Emergency Fund",
                onClose: closeCreateSavingsCategoryDialog
            )
            .frame(minWidth: 280)
        }  
        .sheet(isPresented: $isCreatingDebtDialogOpen) {
            CreateCategoryView(
                type: .debt,
                hint: "Mortgage",
                onClose: closeCreateDebtCategoryDialog
            )
            .frame(minWidth: 280)
        }
        .sheet(isPresented: $isCreatingCategoryDialogOpen) {
            CreateGeneralCategoryView(
                onClose: closeCreateCategoryDialog
            )
            .frame(minWidth: 280)
        }
        .sheet(isPresented: $isCreatingTransactionDialogOpen) {
            CreateTransactionView(
                onClose: closeCreateTransactionDialog
            )
            .frame(minWidth: 360)
        }
        .confirmationDialog(
            "Delete \(categoryPendingDeletion?.title ?? "Category")?",
            isPresented: Binding(
                get: {
                    categoryPendingDeletion != nil
                },
                set: { isPresented in
                    if !isPresented {
                        categoryPendingDeletion = nil
                    }
                }
            )
        ) {
            Button("Delete Category", role: .destructive) {
                if let category = categoryPendingDeletion {
                    deleteCategory(category)
                }

                categoryPendingDeletion = nil
            }
            .accessibilityIdentifier("categoryTableDeleteConfirmButton")

            Button("Cancel", role: .cancel) {
                categoryPendingDeletion = nil
            }
        } message: {
            Text("This will remove the category and its transactions from the budget.")
        }
    }

}
