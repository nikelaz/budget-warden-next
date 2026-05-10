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

struct BudgetDetailView: View {
    @ObservedObject var store: BWStore
    @ObservedObject var windowStore: BWWindowStore
    var budget: BudgetRow
    @State private var isCreatingTransaction = false
    @State private var transactionCategoryID: Int?
    @State private var isReportingExpanded = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ForEach(BudgetCategoryType.allCases) { type in
                    categoryList(for: type)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .frame(
            maxWidth: .infinity,
            maxHeight: .infinity,
            alignment: .topLeading
        )
        .navigationTitle("Budget")
        .toolbar {
            ToolbarItemGroup(placement: .principal) {
                Menu {
                    ForEach(store.availableBudgetRows) { budget in
                        Button {
                            store.selectBudget(budget)
                        } label: {
                            if store.selectedBudgetURL?.standardizedFileURL == budget.url.standardizedFileURL {
                                Label(budget.title, systemImage: "checkmark")
                            } else {
                                Text(budget.title)
                            }
                        }
                    }

                    Divider()

                    Button {
                        windowStore.showCreateBudget()
                    } label: {
                        Label("New Budget", systemImage: "plus")
                    }
                } label: {
                    Text(budget.title)
                }
                
                Button {
                    transactionCategoryID = nil
                    isCreatingTransaction = true
                } label: {
                    Text("Transaction")
                    Image(systemName: "plus")
                }
                .help("Add Transaction")
                .disabled(!store.hasCategories(in: budget.url))
            }
            
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    isReportingExpanded.toggle()
                } label: {
                    Image(systemName: isReportingExpanded ? "sidebar.right" : "chart.bar.xaxis")
                }
                .help(isReportingExpanded ? "Hide Reporting" : "Show Reporting")
            }
        }
        .inspector(isPresented: $isReportingExpanded) {
            BudgetReportingView(
                store: store,
                budgetURL: budget.url,
                currency: store.selectedCurrency,
                isExpanded: $isReportingExpanded,
                scope: .inspector
            )
            .inspectorColumnWidth(min: 300, ideal: 420, max: 600)
        }
        .sheet(isPresented: $isCreatingTransaction) {
            CreateTransactionView(
                store: store,
                budgetURL: budget.url,
                initialCategoryID: transactionCategoryID,
                onSave: { draft in
                    store.addTransaction(draft)
                    isCreatingTransaction = false
                    transactionCategoryID = nil
                },
                onCancel: {
                    isCreatingTransaction = false
                    transactionCategoryID = nil
                }
            )
            .frame(minWidth: 420)
        }
    }

    private func categoryList(for type: BudgetCategoryType) -> some View {
        CategoryListView(
            store: store,
            budgetURL: budget.url,
            type: type,
            currency: store.selectedCurrency
        ) { title, amountPlanned, amountAccumulated in
            store.addCategory(title: title, amountPlanned: amountPlanned, amountAccumulated: amountAccumulated, type: type)
        } onUpdateCategory: { update in
            store.updateCategory(update)
        } onRemoveCategory: { categoryID in
            store.removeCategory(categoryID: categoryID)
        } onReorderCategories: { orderedCategoryIDs in
            store.reorderCategories(type: type, orderedCategoryIDs: orderedCategoryIDs)
        } onAddTransaction: { categoryID in
            transactionCategoryID = categoryID
            isCreatingTransaction = true
        }
    }
}
