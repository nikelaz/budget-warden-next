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

struct BWWorkspaceView: View {
    let store: BWAppStore
    let budgetID: UUID
    let createBudget: () -> Void
    let showBudgetList: () -> Void

    @State private var selectedTab: BWWorkspaceTab = .budget
    @State private var categoryEditor: BWCategoryEditor?
    @State private var transactionEditor: BWTransactionEditor?
    @State private var transactionSearchText: String = ""

    private var budget: BWBudget? {
        store.budget(withID: budgetID)
    }

    var body: some View {
        if let budget {
            TabView(selection: $selectedTab) {
                BWDetailView(
                    store: store,
                    budget: budget,
                    currency: store.selectedCurrency,
                    editor: $categoryEditor
                )
                    .tabItem {
                        Label("Budget", systemImage: "list.bullet.rectangle")
                    }
                    .tag(BWWorkspaceTab.budget)

                BWReportingView(
                    budget: budget,
                    currency: store.selectedCurrency
                )
                    .tabItem {
                        Label("Reporting", systemImage: "chart.pie")
                    }
                    .tag(BWWorkspaceTab.reporting)

                BWTransactionsView(
                    store: store,
                    budget: budget,
                    currency: store.selectedCurrency,
                    editor: $transactionEditor,
                    searchText: $transactionSearchText
                )
                .tabItem {
                    Label("Transactions", systemImage: "list.bullet.clipboard")
                }
                .tag(BWWorkspaceTab.transactions)

                BWSettingsView(
                    store: store,
                    budget: budget
                )
                    .tabItem {
                        Label("Settings", systemImage: "gearshape")
                    }
                    .tag(BWWorkspaceTab.settings)
            }
            .navigationTitle(budget.title)
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarBackButtonHidden(true)
            .toolbar {
                ToolbarTitleMenu {
                    Button {
                        showBudgetList()
                    } label: {
                        Label("All Budgets", systemImage: "list.bullet")
                    }

                    Divider()

                    ForEach(store.budgets) { budget in
                        Button {
                            store.selectBudget(withID: budget.id)
                        } label: {
                            if budget.id == budgetID {
                                Label(budget.title, systemImage: "checkmark")
                            }
                            else {
                                Text(budget.title)
                            }
                        }
                    }

                    Divider()

                    Button {
                        createBudget()
                    } label: {
                        Label("New Budget", systemImage: "plus")
                    }
                }

                if selectedTab == .budget {
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            Button {
                                createBudget()
                            } label: {
                                Label("Budget", systemImage: "rectangle.stack.badge.plus")
                            }

                            Button {
                                categoryEditor = .create(.expenses)
                            } label: {
                                Label("Category", systemImage: "folder.badge.plus")
                            }

                            Button {
                                transactionEditor = .create(initialCategoryID: orderedCategories(in: budget).first?.id)
                            } label: {
                                Label("Transaction", systemImage: "receipt")
                            }
                            .disabled(budget.categories.isEmpty)
                        } label: {
                            Image(systemName: "plus")
                        }
                        .accessibilityLabel("Add")
                    }
                }

                if selectedTab == .transactions {
                    ToolbarItem(placement: .primaryAction) {
                        Button("New Transaction", systemImage: "plus") {
                            transactionEditor = .create(initialCategoryID: orderedCategories(in: budget).first?.id)
                        }
                        .disabled(budget.categories.isEmpty)
                    }
                }
            }
        }
        else {
            ContentUnavailableView("Budget Not Found", systemImage: "folder.badge.questionmark")
        }
    }

    private func orderedCategories(in budget: BWBudget) -> [BWCategory] {
        BWBudgetMutation.orderedCategories(in: budget)
    }
}

private enum BWWorkspaceTab: Hashable {
    case budget
    case reporting
    case transactions
    case settings
}
