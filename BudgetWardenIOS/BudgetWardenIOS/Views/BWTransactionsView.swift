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

struct BWTransactionsView: View {
    let store: BWAppStore
    let budget: BWBudget
    let currency: BWCurrency
    @Binding var editor: BWTransactionEditor?
    @Binding var searchText: String

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
        List {
            if transactions.isEmpty {
                ContentUnavailableView("No Transactions", systemImage: "tray")
            }
            else if filteredTransactions.isEmpty {
                ContentUnavailableView.search(text: searchText)
            }
            else {
                ForEach(filteredTransactions) { item in
                    Button {
                        editor = .edit(item)
                    } label: {
                        transactionRow(item)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                        .swipeActions(edge: .trailing) {
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                Task {
                                    await deleteTransaction(item)
                                }
                            }

                            Button("Edit", systemImage: "pencil") {
                                editor = .edit(item)
                            }
                            .tint(.blue)
                        }
                        .contextMenu {
                            Button("Edit", systemImage: "pencil") {
                                editor = .edit(item)
                            }

                            Button("Delete", systemImage: "trash", role: .destructive) {
                                Task {
                                    await deleteTransaction(item)
                                }
                            }
                        }
                }
                .onDelete { offsets in
                    deleteTransactions(at: offsets)
                }
            }
        }
        .sheet(item: $editor) { editor in
            BWTransactionEditorView(
                editor: editor,
                categories: orderedCategories(),
                currency: currency,
                saveTransaction: saveTransaction
            )
        }
    }

    private func transactionRow(_ item: BWTransactionListItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(item.transaction.title)
                    .font(.body)

                Spacer()

                Text(item.transaction.amount.formattedMoneyAmount(currency: currency))
                    .font(.body.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 6) {
                Text(item.category.title)

                if !item.transaction.description.isEmpty {
                    Text("•")
                    Text(item.transaction.description)
                        .lineLimit(1)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func orderedCategories() -> [BWCategory] {
        budget.categories.enumerated()
            .sorted { lhs, rhs in
                if lhs.element.categoryType != rhs.element.categoryType {
                    return lhs.element.categoryType.rawValue < rhs.element.categoryType.rawValue
                }

                if lhs.element.ordinal == rhs.element.ordinal {
                    return lhs.offset < rhs.offset
                }

                return lhs.element.ordinal < rhs.element.ordinal
            }
            .map(\.element)
    }

    private func deleteTransactions(at offsets: IndexSet) {
        let itemsToDelete = offsets.compactMap { index in
            filteredTransactions.indices.contains(index) ? filteredTransactions[index] : nil
        }

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

    private func saveTransaction(_ draft: BWTransactionDraft) async -> Bool {
        switch draft.mode {
            case .create:
                return await store.createTransaction(
                    in: budget.id,
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
                    in: budget.id,
                    from: item.category.id,
                    to: draft.categoryID
                )
        }
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
