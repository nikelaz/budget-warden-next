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

    var body: some View {
        List {
            if store.isLoadingBudgets {
                ProgressView()
            }

            ForEach(store.budgets) { budget in
                NavigationLink(value: budget.id) {
                    BWSummaryRow(budget: budget)
                }
                .contextMenu {
                    Button("Delete", systemImage: "trash", role: .destructive) {
                        Task {
                            await store.deleteBudget(budget)
                        }
                    }
                }
            }
            .onDelete { offsets in
                Task {
                    await store.deleteBudgets(at: offsets)
                }
            }
        }
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
            }

            ToolbarItem(placement: .topBarLeading) {
                Button("Vault", systemImage: "folder.badge.gearshape", action: configureVault)
            }
        }
    }
}
