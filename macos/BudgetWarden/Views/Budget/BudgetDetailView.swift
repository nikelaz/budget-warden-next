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
    let budgets: [BudgetRow]
    let budget: BudgetRow
    let currency: AppCurrency
    let selectedBudgetURL: URL?
    let onCreateBudget: () -> Void
    let onSelectBudget: (BudgetRow) -> Void
    let onAddCategory: (Swift.String, UInt64, UInt64, BudgetCategoryType) -> Void
    let onUpdateCategory: (CategoryUpdate) -> Void
    let onRemoveCategory: (Int) -> Void
    let onReorderCategories: (BudgetCategoryType, [Int]) -> Void
    let onAddTransaction: (TransactionDraft) -> Void

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
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle("Budget")
        .toolbar {
            ToolbarItemGroup(placement: .principal) {
                Menu {
                    ForEach(budgets) { budget in
                        Button {
                            onSelectBudget(budget)
                        } label: {
                            if selectedBudgetURL?.standardizedFileURL == budget.url.standardizedFileURL {
                                Label(budget.title, systemImage: "checkmark")
                            } else {
                                Text(budget.title)
                            }
                        }
                    }

                    Divider()

                    Button {
                        onCreateBudget()
                    } label: {
                        Label("New Budget", systemImage: "plus")
                    }
                } label: {
                    Text(budget.title)
                }
                .accessibilityIdentifier("budget-menu")
                
                Button {
                    transactionCategoryID = nil
                    isCreatingTransaction = true
                } label: {
                    Text("Transaction")
                    Image(systemName: "plus")
                }
                .help("Add Transaction")
                .accessibilityIdentifier("budget-add-transaction-button")
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
                currency: currency,
                isExpanded: $isReportingExpanded,
                scope: .inspector
            )
            .inspectorColumnWidth(min: 300, ideal: 340, max: 420)
        }
        .sheet(isPresented: $isCreatingTransaction) {
            CreateTransactionView(
                store: store,
                budgetURL: budget.url,
                initialCategoryID: transactionCategoryID,
                onSave: { draft in
                    onAddTransaction(draft)
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
            currency: currency
        ) { title, amountPlanned, amountAccumulated in
            onAddCategory(title, amountPlanned, amountAccumulated, type)
        } onUpdateCategory: { update in
            onUpdateCategory(update)
        } onRemoveCategory: { categoryID in
            onRemoveCategory(categoryID)
        } onReorderCategories: { orderedCategoryIDs in
            onReorderCategories(type, orderedCategoryIDs)
        } onAddTransaction: { categoryID in
            transactionCategoryID = categoryID
            isCreatingTransaction = true
        }
    }
}
