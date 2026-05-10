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

struct MainLayoutView: View {
    @ObservedObject var store: BWStore
    @StateObject private var windowStore = BWWindowStore()
    @State private var selectedSection: SidebarSection = .budget

    var body: some View {
        NavigationSplitView {
            SidebarView(
                selectedSection: $selectedSection
            )
        } detail: {
            if let selectedBudget = store.selectedBudgetRow {
                switch selectedSection {
                case .budget:
                    BudgetDetailView(
                        store: store,
                        budgets: store.availableBudgetRows,
                        budget: selectedBudget,
                        currency: store.selectedCurrency,
                        selectedBudgetURL: store.selectedBudgetURL,
                        onCreateBudget: showCreateBudget,
                        onSelectBudget: store.selectBudget,
                        onAddCategory: store.addCategory,
                        onUpdateCategory: store.updateCategory,
                        onRemoveCategory: store.removeCategory,
                        onReorderCategories: store.reorderCategories,
                        onAddTransaction: store.addTransaction
                    )
                case .reporting:
                    ReportingView(
                        store: store,
                        budgets: store.availableBudgetRows,
                        budget: selectedBudget,
                        currency: store.selectedCurrency,
                        selectedBudgetURL: store.selectedBudgetURL,
                        onCreateBudget: showCreateBudget,
                        onSelectBudget: store.selectBudget,
                        onAddTransaction: store.addTransaction
                    )
                case .transactions:
                    TransactionsView(
                        store: store,
                        budgets: store.availableBudgetRows,
                        budget: selectedBudget,
                        currency: store.selectedCurrency,
                        selectedBudgetURL: store.selectedBudgetURL,
                        onCreateBudget: showCreateBudget,
                        onSelectBudget: store.selectBudget,
                        onAddTransaction: store.addTransaction,
                        onUpdateTransaction: store.updateTransaction,
                        onRemoveTransaction: store.removeTransaction
                    )
                }
            } else {
                ContentUnavailableView(
                    "No Budget Selected",
                    systemImage: "creditcard.and.123"
                )
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            showCreateBudget()
                        } label: {
                            Label("Create New Budget", systemImage: "plus")
                        }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            windowStore.showPreferences()
                        } label: {
                            Label("Preferences", systemImage: "gearshape")
                        }
                    }
                }
            }
        }
        .task {
            store.loadBudgets()
        }
        .focusedSceneValue(\.budgetWindowStore, windowStore)
        .sheet(isPresented: $windowStore.isCreatingBudget) {
            CreateBudgetView(
                store: store,
                onSave: { draft in
                    _ = windowStore.createBudget(draft, store: store)
                },
                onCancel: windowStore.cancelCreateBudget
            )
            .frame(minWidth: 420)
        }
        .sheet(isPresented: $windowStore.isConfiguringVault) {
            VaultSetupView(
                initialLocalParentURL: store.configuredLocalVaultParentURL
            ) {
                windowStore.configureVault(preferICloud: true, store: store)
            } onChooseLocal: { parentURL in
                windowStore.configureVault(parentURL: parentURL, store: store)
            } onCancel: {
                windowStore.cancelVaultSetup(store: store)
            }
            .frame(minWidth: 440)
        }
        .sheet(isPresented: $windowStore.isShowingPreferences) {
            PreferencesView(
                selectedCurrency: $store.selectedCurrency,
                onClose: {
                    windowStore.closePreferences()
                }
            )
            .frame(minWidth: 360)
        }
        .alert(
            "Budget Warden",
            isPresented: errorBinding
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.presentedError ?? "")
        }
    }

    private func showCreateBudget() {
        windowStore.showCreateBudget()
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { store.presentedError != nil },
            set: {
                if !$0 {
                    store.presentedError = nil
                }
            }
        )
    }

}
