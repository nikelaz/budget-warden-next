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

struct BudgetView: View {
    @ObservedObject var store: BWStore
    @ObservedObject var windowStore: BWWindowStore

    @State var newTitle = ""

    var body: some View {
        VStack {
            Table(of: BWCategory.self) {
                TableColumn("") { category in
                    Text(category.title)
                        .padding(5)
                }
                TableColumn("Planned") { category in
                    Text(String(category.amountPlanned))
                }
                TableColumn("Actual") { category in
                    Text(String(category.amountActual))
                }
            } rows: {
                Section("Income") {
                    ForEach(store.currentBudget!.categories.filter { $0.categoryType == .income }) { category in
                        TableRow(category)
                    }
                }

                Section("Expenses") {
                    ForEach(store.currentBudget!.categories.filter { $0.categoryType == .expenses }) { category in
                        TableRow(category)
                    }
                }

                Section("Savings") {
                    ForEach(store.currentBudget!.categories.filter { $0.categoryType == .savings }) { category in
                        TableRow(category)
                    }
                }

                Section("Debt") {
                    ForEach(store.currentBudget!.categories.filter { $0.categoryType == .debt }) { category in
                        TableRow(category)
                    }
                }
            }
            .tableStyle(.inset(alternatesRowBackgrounds: true))
        }
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
    }
}
