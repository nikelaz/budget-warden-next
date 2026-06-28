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
import SwiftUI

struct BWTransactionsView: View {
    let store: BWStore
    let budget: BWBudget
    let currency: BWCurrency
    @Binding var searchText: String
    @Binding var transactionPendingEdit: BWTransactionListItem?
    let navigationTransitionNamespace: Namespace.ID
    let saveTransaction: (BWTransactionDraft) async -> Bool

    @State private var transactionsPendingDeletion: [BWTransactionListItem] = []

    private var transactions: [BWTransactionListItem] {
        budget.categories.flatMap { category in
            category.transactions.map { transaction in
                BWTransactionListItem(
                    category: category,
                    transaction: transaction
                )
            }
        }
        .sorted { lhs, rhs in
            if lhs.transaction.date == rhs.transaction.date {
                return lhs.transaction.title.localizedStandardCompare(rhs.transaction.title) == .orderedAscending
            }

            return lhs.transaction.date > rhs.transaction.date
        }
    }

    private var filteredTransactions: [BWTransactionListItem] {
        let trimmedSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedSearch.isEmpty else {
            return transactions
        }

        return transactions.filter { item in
            searchableText(for: item).localizedCaseInsensitiveContains(trimmedSearch)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            List {
                Section {
                    searchField
                }

                if transactions.isEmpty {
                    ContentUnavailableView("No Transactions", systemImage: "tray")
                }
                else if filteredTransactions.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                }
                else {
                    ForEach(filteredTransactions) { item in
                        NavigationLink {
                            transactionEditor(for: item)
                        } label: {
                            transactionRow(item)
                                .matchedTransitionSource(id: item.id, in: navigationTransitionNamespace)
                        }
                        .swipeActions(edge: .trailing) {
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                Task {
                                    await deleteTransaction(item)
                                }
                            }

                            Button("Edit", systemImage: "pencil") {
                                transactionPendingEdit = item
                            }
                            .tint(.blue)
                        }
                        .contextMenu {
                            Button("Edit", systemImage: "pencil") {
                                transactionPendingEdit = item
                            }

                            Button("Delete", systemImage: "trash", role: .destructive) {
                                confirmDeletion(of: [item])
                            }
                        }
                    }
                    .onDelete { offsets in
                        deleteTransactions(at: offsets)
                    }
                }
            }
            .contentMargins(.top, 5, for: .scrollContent)
        }
        .alert(
            deleteConfirmationTitle,
            isPresented: Binding(
                get: { !transactionsPendingDeletion.isEmpty },
                set: { isPresented in
                    if !isPresented {
                        transactionsPendingDeletion = []
                    }
                }
            ),
            actions: {
                Button(deleteConfirmationActionTitle, role: .destructive) {
                    deletePendingTransactions()
                }
                .accessibilityIdentifier("transactionDeleteConfirmButton")

                Button("Cancel", role: .cancel) {
                    transactionsPendingDeletion = []
                }
            },
            message: {
                Text("This action cannot be undone.")
            }
        )
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("Search transactions", text: $searchText)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .accessibilityIdentifier("transactionSearchTextField")

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Clear search")
                .accessibilityIdentifier("clearTransactionSearchButton")
            }
        }
    }

    private func transactionRow(_ item: BWTransactionListItem) -> some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.transaction.title)
                    .font(.body)
                    .accessibilityIdentifier("transactionTitle_\(item.transaction.title)")
                Text(item.category.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("transactionCategory_\(item.transaction.title)")
            }

            Spacer()

            Text(item.transaction.amount.formattedMoneyAmount(currency: currency))
                .font(.body.monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("transactionAmount_\(item.transaction.title)")

        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("transactionRow_\(item.transaction.title)")
    }

    private func transactionEditor(for item: BWTransactionListItem) -> some View {
        BWTransactionDetailsView(
            editor: .edit(item),
            categories: orderedCategories(),
            currency: currency,
            saveTransaction: saveTransaction,
            deleteTransaction: {
                await deleteTransaction(item)
            },
            embedsInNavigationStack: false,
            showsCancelButton: false
        )
        .navigationTransition(.zoom(sourceID: item.id, in: navigationTransitionNamespace))
    }

    private func orderedCategories() -> [BWCategory] {
        budget.orderedCategories()
    }

    private func deleteTransactions(at offsets: IndexSet) {
        let itemsToDelete = offsets.compactMap { index in
            filteredTransactions.indices.contains(index) ? filteredTransactions[index] : nil
        }

        confirmDeletion(of: itemsToDelete)
    }

    private func confirmDeletion(of items: [BWTransactionListItem]) {
        transactionsPendingDeletion = items
    }

    private func deletePendingTransactions() {
        let itemsToDelete = transactionsPendingDeletion
        transactionsPendingDeletion = []

        Task {
            for item in itemsToDelete {
                await deleteTransaction(item)
            }
        }
    }

    private func deleteTransaction(_ item: BWTransactionListItem) async {
        await store.deleteTransaction(
            item.transaction,
            in: budget.id,
            from: item.category.id
        )
    }

    private func searchableText(for item: BWTransactionListItem) -> String {
        [
            item.transaction.title,
            item.transaction.description,
            item.category.title,
            item.category.categoryType.title,
            item.transaction.amount.formattedMoneyAmount(currency: currency),
            item.transaction.amount.moneyInputText,
            item.transaction.date.formatted(date: .abbreviated, time: .omitted)
        ]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private var deleteConfirmationTitle: String {
        transactionsPendingDeletion.count == 1 ? "Delete Transaction?" : "Delete Transactions?"
    }

    private var deleteConfirmationActionTitle: String {
        transactionsPendingDeletion.count == 1 ? "Delete Transaction" : "Delete Transactions"
    }
}

struct BWTransactionListItem: Identifiable {
    var category: BWCategory
    var transaction: BWTransaction

    var id: UUID {
        transaction.id
    }
}

enum BWTransactionEditor: Identifiable {
    case create(initialCategoryID: UUID?)
    case edit(BWTransactionListItem)

    var id: String {
        switch self {
            case .create(let initialCategoryID):
                return "create-\(initialCategoryID?.uuidString ?? "none")"
            case .edit(let item):
                return "edit-\(item.transaction.id.uuidString)"
        }
    }

    var title: String {
        switch self {
            case .create:
                return "New Transaction"
            case .edit:
                return "Edit Transaction"
        }
    }
}

enum BWTransactionDraftMode {
    case create
    case edit(BWTransactionListItem)
}

struct BWTransactionDraft {
    var mode: BWTransactionDraftMode
    var categoryID: UUID
    var title: String
    var description: String
    var date: Date
    var amount: UInt64
}
