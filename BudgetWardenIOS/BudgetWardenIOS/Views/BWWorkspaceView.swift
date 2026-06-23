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
    @State private var categoryPendingEdit: BWCategory?
    @State private var transactionEditor: BWTransactionEditor?
    @State private var transactionPendingEdit: BWTransactionListItem?
    @State private var transactionSearchText: String = ""
    @Namespace private var editorNavigationNamespace

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
                    editor: $categoryEditor,
                    categoryPendingEdit: $categoryPendingEdit,
                    navigationTransitionNamespace: editorNavigationNamespace,
                    saveCategory: saveCategory
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
                    searchText: $transactionSearchText,
                    transactionPendingEdit: $transactionPendingEdit,
                    navigationTransitionNamespace: editorNavigationNamespace,
                    saveTransaction: saveTransaction
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
            .tabViewStyle(.sidebarAdaptable)
            .navigationTitle(budget.title)
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarBackButtonHidden(true)
            .sheet(item: $transactionEditor) { editor in
                BWTransactionEditorView(
                    editor: editor,
                    categories: orderedCategories(in: budget),
                    currency: store.selectedCurrency,
                    saveTransaction: saveTransaction
                )
            }
            .navigationDestination(
                isPresented: categoryEditIsPresented
            ) {
                if let categoryPendingEdit {
                    categoryEditor(for: categoryPendingEdit)
                }
            }
            .navigationDestination(
                isPresented: transactionEditIsPresented
            ) {
                if let transactionPendingEdit {
                    transactionEditor(for: transactionPendingEdit, in: budget)
                }
            }
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
                    .accessibilityIdentifier("budgetSwitcher_\(budget.title)")

                    Divider()

                    Button {
                        createBudget()
                    } label: {
                        Label("New Budget", systemImage: "plus")
                    }
                    .accessibilityIdentifier("titleMenuNewBudgetButton")
                }

                if selectedTab == .budget {
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            Button {
                                createBudget()
                            } label: {
                                Label("Budget", systemImage: "rectangle.stack.badge.plus")
                            }
                            .accessibilityIdentifier("workspaceAddBudgetButton")

                            Button {
                                categoryEditor = .create(.expenses)
                            } label: {
                                Label("Category", systemImage: "folder.badge.plus")
                            }
                            .accessibilityIdentifier("workspaceAddCategoryButton")

                            Button {
                                transactionEditor = .create(initialCategoryID: orderedCategories(in: budget).first?.id)
                            } label: {
                                Label("Transaction", systemImage: "receipt")
                            }
                            .accessibilityIdentifier("workspaceAddTransactionButton")
                            .disabled(budget.categories.isEmpty)
                        } label: {
                            Image(systemName: "plus")
                        }
                        .accessibilityLabel("Add")
                        .accessibilityIdentifier("workspaceAddMenu")
                    }
                }

                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showBudgetList()
                    } label: {
                        Label("All Budgets", systemImage: "list.bullet")
                    }
                    .accessibilityIdentifier("allBudgetsButton")
                }

                if selectedTab == .transactions {
                    ToolbarItem(placement: .primaryAction) {
                        Button("New Transaction", systemImage: "plus") {
                            transactionEditor = .create(initialCategoryID: orderedCategories(in: budget).first?.id)
                        }
                        .accessibilityIdentifier("newTransactionButton")
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

    private var categoryEditIsPresented: Binding<Bool> {
        Binding(
            get: { categoryPendingEdit != nil },
            set: { isPresented in
                if !isPresented {
                    categoryPendingEdit = nil
                }
            }
        )
    }

    private var transactionEditIsPresented: Binding<Bool> {
        Binding(
            get: { transactionPendingEdit != nil },
            set: { isPresented in
                if !isPresented {
                    transactionPendingEdit = nil
                }
            }
        )
    }

    private func categoryEditor(for category: BWCategory) -> some View {
        BWCategoryEditorView(
            editor: .edit(category),
            currency: store.selectedCurrency,
            saveCategory: saveCategory,
            deleteCategory: {
                await store.deleteCategory(category, in: budgetID)
            },
            embedsInNavigationStack: false,
            showsCancelButton: false
        )
        .navigationTransition(.zoom(sourceID: category.id, in: editorNavigationNamespace))
    }

    private func transactionEditor(for item: BWTransactionListItem, in budget: BWBudget) -> some View {
        BWTransactionEditorView(
            editor: .edit(item),
            categories: orderedCategories(in: budget),
            currency: store.selectedCurrency,
            saveTransaction: saveTransaction,
            deleteTransaction: {
                await store.deleteTransaction(
                    item.transaction,
                    in: budgetID,
                    from: item.category.id
                )
            },
            embedsInNavigationStack: false,
            showsCancelButton: false
        )
        .navigationTransition(.zoom(sourceID: item.id, in: editorNavigationNamespace))
    }

    private func saveCategory(_ draft: BWCategoryDraft) async -> Bool {
        switch draft.mode {
            case .create:
                return await store.createCategory(
                    in: budgetID,
                    title: draft.title,
                    plannedAmount: draft.plannedAmount,
                    categoryType: draft.categoryType
                )
            case .edit(let originalCategory):
                var category = originalCategory
                category.title = draft.title
                category.amountPlanned = draft.plannedAmount
                category.categoryType = draft.categoryType

                return await store.updateCategory(category, in: budgetID)
        }
    }

    private func saveTransaction(_ draft: BWTransactionDraft) async -> Bool {
        switch draft.mode {
            case .create:
                return await store.createTransaction(
                    in: budgetID,
                    categoryID: draft.categoryID,
                    title: draft.title,
                    description: draft.description,
                    date: draft.date,
                    amount: draft.amount
                )
            case .edit(let item):
                let transaction = BWTransaction(
                    id: item.transaction.id,
                    title: draft.title,
                    description: draft.description,
                    date: draft.date,
                    amount: draft.amount
                )

                return await store.updateTransaction(
                    transaction,
                    in: budgetID,
                    from: item.category.id,
                    to: draft.categoryID
                )
        }
    }
}

private enum BWWorkspaceTab: Hashable {
    case budget
    case reporting
    case transactions
    case settings
}
