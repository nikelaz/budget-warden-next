/*
 * Budget Warden
 * Copyright (c) 2026 Lazarov & Co EOOD
 * Author: Nikola Lazarov
 *
 * Licensed under the Source-Available Educational License.
 * See the LICENSE file in the project root for full terms.
 *
 */

import BudgetWardenAppleCore
import CloudKit
import SwiftUI

struct BWBudgetListView: View {
    let store: BWStore
    let createBudget: () -> Void
    let configureVault: () -> Void
    let navigationTransitionNamespace: Namespace.ID

    @State private var budgetsPendingDeletion: [BWBudget] = []
    @State private var preparedShare: BWPreparedCloudShare?
    @State private var sharingError: String?
    @State private var isPreparingShare = false

    var body: some View {
        List {
            if store.isLoadingBudgets {
                ProgressView()
            }

            if !store.iCloudBudgets.isEmpty {
                budgetSection(
                    title: "iCloud",
                    budgets: store.iCloudBudgets,
                    canShare: true
                )
            }

            if !store.localBudgets.isEmpty {
                budgetSection(
                    title: "Local",
                    budgets: store.localBudgets,
                    canShare: false
                )
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
        .alert("Could Not Share Budget", isPresented: sharingErrorIsPresented) {
        } message: {
            Text(sharingError ?? "")
        }
        .sheet(item: $preparedShare) { prepared in
            BWCloudSharingView(share: prepared.share)
        }
        .overlay {
            if isPreparingShare {
                BWPreparingCloudShareView()
            }
            else if !store.isLoadingBudgets && store.budgets.isEmpty {
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
                Button("Storage", systemImage: "folder.badge.gearshape", action: configureVault)
                    .accessibilityIdentifier("vaultButton")
            }
        }
        .onAppear {
            updateAutoRefreshDeleteBlocker()
        }
        .onDisappear {
            store.setAutoRefreshSuspended(false, reason: "budgetListDelete")
        }
        .onChange(of: budgetsPendingDeletion.map(\.id)) { _, _ in
            updateAutoRefreshDeleteBlocker()
        }
    }

    @ViewBuilder
    private func budgetSection(
        title: String,
        budgets: [BWBudget],
        canShare: Bool
    ) -> some View {
        Section(title) {
            ForEach(budgets) { budget in
                NavigationLink(value: budget.id) {
                    HStack {
                        Text(budget.title)
                            .font(.headline)
                            .matchedTransitionSource(id: budget.id, in: navigationTransitionNamespace)

                        if canShare && store.sharedBudgetIDs.contains(budget.id) {
                            Text("Shared")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .accessibilityIdentifier("budgetRow_\(budget.title)")
                .contextMenu {
                    if canShare {
                        Button(
                            store.sharedBudgetIDs.contains(budget.id) ? "Manage Sharing" : "Share with iCloud",
                            systemImage: "person.crop.circle.badge.plus"
                        ) {
                            prepareShare(for: budget)
                        }
                    }

                    Button("Delete", systemImage: "trash", role: .destructive) {
                        confirmDeletion(of: [budget])
                    }
                }
            }
            .onDelete { offsets in
                deleteBudgets(at: offsets, in: budgets)
            }
        }
    }

    private func updateAutoRefreshDeleteBlocker() {
        store.setAutoRefreshSuspended(
            !budgetsPendingDeletion.isEmpty,
            reason: "budgetListDelete"
        )
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

    private func deleteBudgets(at offsets: IndexSet, in source: [BWBudget]) {
        let budgets = offsets.compactMap { index in
            source.indices.contains(index) ? source[index] : nil
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

    private func prepareShare(for budget: BWBudget) {
        guard !isPreparingShare else {
            return
        }

        guard store.isICloudEnabled else {
            sharingError = "Enable iCloud in Storage settings before sharing a budget."
            return
        }

        isPreparingShare = true

        Task {
            let result = await store.cloudRepository.prepareShare(for: budget)
            isPreparingShare = false

            switch result {
                case .failure(let error):
                    sharingError = error.localizedDescription
                case .success(let share):
                    preparedShare = BWPreparedCloudShare(share: share)
            }
        }
    }

    private var sharingErrorIsPresented: Binding<Bool> {
        Binding(
            get: { sharingError != nil },
            set: { isPresented in
                if !isPresented {
                    sharingError = nil
                }
            }
        )
    }
}
