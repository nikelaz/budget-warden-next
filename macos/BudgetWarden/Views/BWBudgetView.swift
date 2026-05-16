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

    @State private var selection = Set<BWCategoryTableRow.ID>()
    
    @State var newTitle = ""
    @State var isCreatingIncomeDialogOpen: Bool = false
    @State var isCreatingExpenseDialogOpen: Bool = false
    @State var isCreatingSavingsDialogOpen: Bool = false
    @State var isCreatingDebtDialogOpen: Bool = false

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

    var body: some View {
        Table(of: BWCategoryTableRow.self, selection: $selection) {
            TableColumn("Category") { tableRow in
                switch tableRow.type {
                    case .regular:
                        Text(tableRow.category!.title)
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
                        }
                }
            }

            TableColumn("Accumulated") { tableRow in
                switch tableRow.type {
                    case .regular:                
                        switch tableRow.categoryType {
                            case .income, .expenses:
                                Text("")
                            case .savings, .debt:     
                            Text(tableRow.category!.amountAccumulated.formattedEUR)
                        }
                    case .footer:
                        Text("")
                }
            }
            
            TableColumn("Planned") { tableRow in
                switch tableRow.type {
                    case .regular:
                        Text(tableRow.category!.amountPlanned.formattedEUR)
                    case .footer:
                        Text("")
                }
            }
            
            TableColumn("Actual") { tableRow in
                switch tableRow.type {
                    case .regular:
                        Text(tableRow.category!.amountActual.formattedEUR)
                    case .footer:
                        Text("")
                }
            }
        } rows: {
            Section("Income") {
                ForEach(store.currentBudget!.categories.filter { $0.categoryType == .income }) { category in
                    TableRow(BWCategoryTableRow(
                        id: category.id.uuidString,
                        type: .regular,
                        categoryType: category.categoryType,
                        category: category
                    ))
                }
                
                TableRow(BWCategoryTableRow(
                    id: "footer-income",
                    type: .footer,
                    categoryType: .income,
                    category: nil
                ))
            }

            Section("Expenses") {
                ForEach(store.currentBudget!.categories.filter { $0.categoryType == .expenses }) { category in
                    TableRow(BWCategoryTableRow(
                        id: category.id.uuidString,
                        type: .regular,
                        categoryType: category.categoryType,
                        category: category
                    ))
                }
                
                TableRow(BWCategoryTableRow(
                    id: "footer-expenses",
                    type: .footer,
                    categoryType: .expenses,
                    category: nil
                ))
            }

            Section("Savings") {
                ForEach(store.currentBudget!.categories.filter { $0.categoryType == .savings }) { category in
                    TableRow(BWCategoryTableRow(
                        id: category.id.uuidString,
                        type: .regular,
                        categoryType: category.categoryType,
                        category: category
                    ))
                }
                
                TableRow(BWCategoryTableRow(
                    id: "footer-savings",
                    type: .footer,
                    categoryType: .savings,
                    category: nil
                ))
            }

            Section("Debt") {
                ForEach(store.currentBudget!.categories.filter { $0.categoryType == .debt }) { category in
                    TableRow(BWCategoryTableRow(
                        id: category.id.uuidString,
                        type: .regular,
                        categoryType: category.categoryType,
                        category: category
                    ))
                }
                
                TableRow(BWCategoryTableRow(
                    id: "footer-debt",
                    type: .footer,
                    categoryType: .debt,
                    category: nil
                ))
            }
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .navigationTitle("Budget")
        .toolbar {
            ToolbarItemGroup(placement: .principal) {
                Menu {
                    ForEach(store.budgetsInVault) { budget in
                        Button {
                            store.selectBudget(budget)
                        } label: {
                            if store.currentBudget!.id == budget.id {
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
                    Text(store.currentBudget!.title)
                }
                
                Button {
                    //@TODO(Niki)
                    /*
                    transactionCategoryID = nil
                    isCreatingTransaction = true
                    */
                } label: {
                    Text("Transaction")
                    Image(systemName: "plus")
                }
                .help("Add Transaction")
                //@TODO(Niki)
                //.disabled(!store.hasCategories(in: budget.url))
            }
           
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    //@TODO(Niki)
                    //isReportingExpanded.toggle()
                } label: {
                    //Image(systemName: isReportingExpanded ? "sidebar.right" : "chart.bar.xaxis")
                    Image(systemName: "chart.bar.xaxis")
                }
            }
        }
        .onChange(of: selection) { _, newValue in
            selection = newValue.filter { !$0.hasPrefix("footer-") }
        }
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
    }
}
