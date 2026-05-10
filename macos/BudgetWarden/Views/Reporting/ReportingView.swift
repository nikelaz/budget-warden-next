/* 
 * Budget Warden Core
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
    let budgets: [BudgetRow]
    let budget: BudgetRow
    let currency: AppCurrency
    let selectedBudgetURL: URL?
    let onCreateBudget: () -> Void
    let onSelectBudget: (BudgetRow) -> Void
    let onAddTransaction: (TransactionDraft) -> Void

    @State private var isCreatingTransaction = false

    var body: some View {
        BudgetReportingView(
            store: store,
            budgetURL: budget.url,
            currency: currency,
            isExpanded: .constant(true),
            scope: .fullPage
        )
        .navigationTitle("Reporting")
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
            }
        }
        .sheet(isPresented: $isCreatingTransaction) {
            CreateTransactionView(
                store: store,
                budgetURL: budget.url,
                initialCategoryID: nil,
                onSave: { draft in
                    onAddTransaction(draft)
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
