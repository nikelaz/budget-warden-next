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

struct ReportingView: View {
    @ObservedObject var store: BWStore
    @ObservedObject var windowStore: BWWindowStore
    let budget: BudgetRow

    @State private var isCreatingTransaction = false

    var body: some View {
        BudgetReportingView(
            store: store,
            budgetURL: budget.url,
            currency: store.selectedCurrency,
            isExpanded: .constant(true),
            scope: .fullPage
        )
        .navigationTitle("Reporting")
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
                .accessibilityIdentifier("budget-menu")
            }
        }
        .sheet(isPresented: $isCreatingTransaction) {
            CreateTransactionView(
                store: store,
                budgetURL: budget.url,
                initialCategoryID: nil,
                onSave: { draft in
                    store.addTransaction(draft)
                    isCreatingTransaction = false
                },
                onCancel: {
                    isCreatingTransaction = false
                }
            )
            .frame(minWidth: 420)
        }
        .accessibilityIdentifier("reporting-root")
    }
}
