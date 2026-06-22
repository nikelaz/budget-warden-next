/*
 * Budget Warden
 * Copyright (c) 2026 Lazarov & Co EOOD
 * Author: Nikola Lazarov
 *
 * Licensed under the Source-Available Educational License.
 * See the LICENSE file in the project root for full terms.
 *
 */

import AppleCore
import SwiftUI

struct BWListView: View {
    let store: BWAppStore
    let createBudget: () -> Void
    let configureVault: () -> Void

    @State private var budgetsPendingDeletion: [BWBudget] = []

    var body: some View {
        List {
            if store.isLoadingBudgets {
                ProgressView()
            }

            ForEach(store.budgets) { budget in
                NavigationLink(value: budget.id) {
                    BWSummaryRow(budget: budget)
                }
                .accessibilityIdentifier("budgetRow_\(budget.title)")
                .contextMenu {
                    Button("Delete", systemImage: "trash", role: .destructive) {
                        confirmDeletion(of: [budget])
                    }
                }
            }
            .onDelete { offsets in
                deleteBudgets(at: offsets)
            }
        }
        .alert(
            deleteConfirmationTitle,
            isPresented: Binding(
                get: { !budgetsPendingDeletion.isEmpty },
                set: { isPresented in
                    if !isPresented {
                        budgetsPendingDeletion = []
                    }
                }
            ),
            actions: {
                Button(deleteConfirmationButtonTitle, role: .destructive) {
                    deletePendingBudgets()
                }
                .accessibilityIdentifier("budgetDeleteConfirmButton")

                Button("Cancel", role: .cancel) {
                    budgetsPendingDeletion = []
                }
            },
            message: {
                Text(deleteConfirmationMessage)
            }
        )
        .overlay {
            if !store.isLoadingBudgets && store.budgets.isEmpty {
                ContentUnavailableView(
                    "No Budgets",
                    systemImage: "folder",
                    description: Text("Create a budget to save it in your vault.")
                )
            }
        }
        .navigationTitle("Budgets")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Add Budget", systemImage: "plus", action: createBudget)
                    .accessibilityIdentifier("addBudgetButton")
            }

            ToolbarItem(placement: .topBarLeading) {
                Button("Vault", systemImage: "folder.badge.gearshape", action: configureVault)
                    .accessibilityIdentifier("vaultButton")
            }
        }
    }

    private var deleteConfirmationTitle: String {
        budgetsPendingDeletion.count == 1 ? "Delete Budget?" : "Delete Budgets?"
    }

    private var deleteConfirmationButtonTitle: String {
        budgetsPendingDeletion.count == 1 ? "Delete Budget" : "Delete Budgets"
    }

    private var deleteConfirmationMessage: String {
        if let budget = budgetsPendingDeletion.first, budgetsPendingDeletion.count == 1 {
            return "\"\(budget.title)\" will be removed from your vault."
        }

        return "\(budgetsPendingDeletion.count) budgets will be removed from your vault."
    }

    private func deleteBudgets(at offsets: IndexSet) {
        let budgets = offsets.compactMap { index in
            store.budgets.indices.contains(index) ? store.budgets[index] : nil
        }

        Task {
            for budget in budgets {
                await store.deleteBudget(budget)
            }
        }
    }

    private func confirmDeletion(of budgets: [BWBudget]) {
        budgetsPendingDeletion = budgets
    }

    private func deletePendingBudgets() {
        let budgets = budgetsPendingDeletion
        budgetsPendingDeletion = []

        Task {
            for budget in budgets {
                await store.deleteBudget(budget)
            }
        }
    }
}
