/* 
 * Budget Warden
 * Copyright (c) 2026 Lazarov & Co EOOD
 * Author: Nikola Lazarov
 *
 * Licensed under the Source-Available Educational License. 
 * See the LICENSE file in the project root for full terms.
 */

import SwiftUI
import BWCore

private struct BWTransactionListItem: Identifiable {
    let id: UUID
    let categoryID: UUID
    let categoryTitle: String
    let categoryTypeTitle: String
    let transaction: BWTransaction

    var title: String {
        transaction.title
    }

    var description: String {
        transaction.description
    }

    var date: Date {
        transaction.date.foundationDate
    }

    var amount: UInt64 {
        transaction.amount.unsignedValue
    }
}

struct BWTransactionsView: View {
    @ObservedObject var store: BWStore
    @ObservedObject var windowStore: BWWindowStore

    @State private var selection: BWTransactionListItem.ID?
    @State private var searchText = ""
    @State private var sortOrder: [KeyPathComparator<BWTransactionListItem>] = [
        KeyPathComparator(\.date, order: .reverse)
    ]
    @State private var isCreatingTransaction = false
    @State private var isFilterPresented = false
    @State private var isDateFilterEnabled = false
    @State private var startDate = Date()
    @State private var endDate = Date()
    @State private var minimumAmount = ""
    @State private var maximumAmount = ""

    private var hasCategories: Bool {
        store.currentBudget?.categories.isEmpty == false
    }

    private var transactions: [BWTransactionListItem] {
        guard let budget = store.currentBudget else {
            return []
        }

        return budget.categories.flatMap { category in
            category.transactions.map { transaction in
                BWTransactionListItem(
                    id: transaction.id,
                    categoryID: category.id,
                    categoryTitle: category.title,
                    categoryTypeTitle: category.categoryType.toString(),
                    transaction: transaction
                )
            }
        }
    }

    private func filteredTransactions(
        from transactions: [BWTransactionListItem]
    ) -> [BWTransactionListItem] {
        transactions
            .filter(matchesFilters)
            .sorted(using: sortOrder)
    }

    private var transactionDateRange: (oldest: Date, newest: Date) {
        let dates = transactions.map(\.date)
        let now = Date()

        return (
            oldest: dates.min() ?? now,
            newest: dates.max() ?? now
        )
    }

    var body: some View {
        let transactions = transactions
        let filteredTransactions = filteredTransactions(from: transactions)
        let selectedTransaction = filteredTransactions.first { $0.id == selection }
        let isSelectionVisible = selection.map { selectedID in
            filteredTransactions.contains { $0.id == selectedID }
        } ?? true

        transactionTable(
            transactions: transactions,
            filteredTransactions: filteredTransactions
        )
            .navigationTitle("Transactions")
            .searchable(text: $searchText, placement: .toolbar, prompt: "Search transactions")
            .onAppear {
                resetFilters()
            }
            .toolbar {
                ToolbarItemGroup(placement: .principal) {
                    Menu {
                        ForEach(store.recentFiles, id: \.self) { url in
                            Button {
                                Task { _ = await store.openBudget(at: url, windowStore: windowStore) }
                            } label: {
                                if store.currentBudget?.url == url.path {
                                    Label(store.currentBudget?.title ?? url.deletingPathExtension().lastPathComponent, systemImage: "checkmark")
                                }
                                else {
                                    Text(url.deletingPathExtension().lastPathComponent)
                                }
                            }
                        }

                        Divider()

                        Button {
                            windowStore.openBudgetDialog()
                        } label: {
                            Label("New Budget", systemImage: "plus")
                        }
                    } label: {
                        Text(store.currentBudget?.title ?? "Budget")
                    }

                    Button {
                        isCreatingTransaction = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add Transaction")
                    .help("Add Transaction")
                    .disabled(!hasCategories)
                }

                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        isFilterPresented.toggle()
                    } label: {
                        Label("Filters", systemImage: "line.3.horizontal.decrease.circle")
                    }
                    .popover(isPresented: $isFilterPresented) {
                        filterView
                            .frame(width: 260)
                            .padding(16)
                    }
                }
            }
            .onChange(of: isSelectionVisible) { _, isVisible in
                if !isVisible {
                    selection = nil
                }
            }
            .onChange(of: store.currentBudget?.id) { _, _ in
                selection = nil
                resetFilters()
            }
            .inspector(isPresented: .constant(true)) {
                if let selectedTransaction {
                    BWTransactionInspectorView(
                        categoryID: selectedTransaction.categoryID,
                        categories: store.currentBudget?.categories ?? [],
                        transaction: selectedTransaction.transaction,
                        deleteTransaction: {
                            Task(priority: .userInitiated) {
                                await store.deleteTransaction(
                                    categoryID: selectedTransaction.categoryID,
                                    transactionID: selectedTransaction.id,
                                    windowStore: windowStore
                                )
                                selection = nil
                            }
                        },
                        saveTransaction: { updatedTransaction in
                            Task(priority: .userInitiated) {
                                _ = await store.updateTransaction(
                                    categoryID: selectedTransaction.categoryID,
                                    transaction: updatedTransaction,
                                    windowStore: windowStore
                                )
                            }
                        },
                        saveCategory: { categoryID in
                            Task(priority: .userInitiated) {
                                if await store.moveTransaction(
                                    transactionID: selectedTransaction.id,
                                    from: selectedTransaction.categoryID,
                                    to: categoryID,
                                    windowStore: windowStore
                                ) {
                                    selection = selectedTransaction.id
                                }
                            }
                        }
                    )
                }
                else {
                    ContentUnavailableView(
                        "Select a transaction",
                        systemImage: "sidebar.right"
                    )
                }
            }
            .sheet(isPresented: $isCreatingTransaction) {
                CreateTransactionView(
                    onClose: {
                        isCreatingTransaction = false
                    }
                )
                .environmentObject(store)
                .environmentObject(windowStore)
                .frame(minWidth: 360)
            }
    }

    private func transactionTable(
        transactions: [BWTransactionListItem],
        filteredTransactions: [BWTransactionListItem]
    ) -> some View {
        Group {
            if transactions.isEmpty {
                ContentUnavailableView(
                    "No Transactions",
                    systemImage: "list.bullet.rectangle"
                )
            }
            else if filteredTransactions.isEmpty {
                if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ContentUnavailableView(
                        "No Matching Transactions",
                        systemImage: "line.3.horizontal.decrease.circle"
                    )
                }
                else {
                    ContentUnavailableView.search(text: searchText)
                }
            }
            else {
                Table(filteredTransactions, selection: $selection, sortOrder: $sortOrder) {
                    TableColumn("Date", value: \.date) { item in
                        Text(item.date.formatted(date: .abbreviated, time: .omitted))
                            .monospacedDigit()
                    }
                    .width(110)

                    TableColumn("Category", value: \.categoryTitle) { item in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.categoryTitle)
                                .lineLimit(1)

                            Text(item.categoryTypeTitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .width(min: 140, ideal: 180)

                    TableColumn("Title", value: \.title) { item in
                        Text(item.title)
                            .lineLimit(1)
                    }

                    TableColumn("Description", value: \.description) { item in
                        Text(item.description.isEmpty ? " " : item.description)
                            .lineLimit(1)
                    }

                    TableColumn("Amount", value: \.amount) { item in
                        Text(item.amount.formattedMoneyAmount(currency: store.selectedCurrency))
                            .monospacedDigit()
                    }
                    .width(120)
                }
                .tableStyle(.inset(alternatesRowBackgrounds: true))
            }
        }
    }

    private var filterView: some View {
        Form {
            Toggle("Date Range", isOn: $isDateFilterEnabled)

            Group {
                DatePicker(
                    "Start Date",
                    selection: $startDate,
                    displayedComponents: .date
                )

                DatePicker(
                    "End Date",
                    selection: $endDate,
                    displayedComponents: .date
                )
            }
            .disabled(!isDateFilterEnabled)

            TextField("Minimum Amount", text: $minimumAmount, prompt: Text("0.00"))
                .textFieldStyle(.roundedBorder)
                .foregroundColor(isValidAmountFilter(minimumAmount) ? .primary : .red)

            TextField("Maximum Amount", text: $maximumAmount, prompt: Text("0.00"))
                .textFieldStyle(.roundedBorder)
                .foregroundColor(isValidAmountFilter(maximumAmount) ? .primary : .red)

            Button("Reset") {
                resetFilters()
            }
        }
    }

    private func matchesFilters(_ item: BWTransactionListItem) -> Bool {
        matchesSearch(item) &&
            matchesDateFilters(item) &&
            matchesAmountFilters(item)
    }

    private func matchesSearch(_ item: BWTransactionListItem) -> Bool {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !query.isEmpty else {
            return true
        }

        let haystack = [
            item.categoryTitle,
            item.categoryTypeTitle,
            item.title,
            item.description,
            item.date.formatted(date: .abbreviated, time: .omitted),
            item.amount.formattedMoneyAmount(currency: store.selectedCurrency),
            item.amount.moneyInputText
        ].joined(separator: " ")

        return haystack.localizedCaseInsensitiveContains(query)
    }

    private func matchesDateFilters(_ item: BWTransactionListItem) -> Bool {
        guard isDateFilterEnabled else {
            return true
        }

        let calendar = Calendar.current
        let transactionDay = calendar.startOfDay(for: item.date)
        let startDay = calendar.startOfDay(for: startDate)
        let endDay = calendar.startOfDay(for: endDate)

        guard transactionDay >= startDay && transactionDay <= endDay else {
            return false
        }

        return true
    }

    private func matchesAmountFilters(_ item: BWTransactionListItem) -> Bool {
        if !minimumAmount.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let minimumAmount = UInt64.parseMoneyAmount(minimumAmount) else {
                return false
            }

            guard item.amount >= minimumAmount else {
                return false
            }
        }

        if !maximumAmount.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let maximumAmount = UInt64.parseMoneyAmount(maximumAmount) else {
                return false
            }

            guard item.amount <= maximumAmount else {
                return false
            }
        }

        return true
    }

    private func isValidAmountFilter(_ text: String) -> Bool {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedText.isEmpty || UInt64.parseMoneyAmount(trimmedText) != nil
    }

    private func resetFilters() {
        let dateRange = transactionDateRange
        isDateFilterEnabled = false
        startDate = dateRange.oldest
        endDate = dateRange.newest
        minimumAmount = ""
        maximumAmount = ""
    }
}
