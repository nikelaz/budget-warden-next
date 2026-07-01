/* 
 * Budget Warden
 * Copyright (c) 2026 Lazarov & Co EOOD
 * Author: Nikola Lazarov
 *
 * Licensed under the Source-Available Educational License. 
 * See the LICENSE file in the project root for full terms.
 *
 */

import SwiftUI
import BudgetWardenAppleCore

struct BWCategoryTransactionsWindowValue: Codable, Hashable {
    let budgetID: UUID
    let categoryID: UUID
}

struct BWCategoryTransactionsWindow: View {
    @EnvironmentObject var store: BWStore
    @StateObject private var windowStore = BWWindowStore()

    let value: BWCategoryTransactionsWindowValue

    @State private var selection: BWTransaction.ID?
    @State private var searchText = ""
    @State private var sortOrder: [KeyPathComparator<BWTransaction>] = [
        KeyPathComparator(\.date, order: .reverse)
    ]
    @State private var isCreatingTransaction = false
    @State private var isFilterPresented = false
    @State private var isDateFilterEnabled = false
    @State private var startDate = Date()
    @State private var endDate = Date()
    @State private var minimumAmount = ""
    @State private var maximumAmount = ""

    private var category: BWCategory? {
        guard store.currentBudget?.id == value.budgetID else {
            return nil
        }

        return store.currentBudget?.categories.first { $0.id == value.categoryID }
    }

    private var title: String {
        guard let category else {
            return "Transactions"
        }

        return "\(category.title) Transactions"
    }

    private var hasAutoRefreshBlockingEditor: Bool {
        isCreatingTransaction || isFilterPresented || windowStore.isErrorState
    }

    private func updateAutoRefreshEditorBlocker() {
        store.setAutoRefreshSuspended(
            hasAutoRefreshBlockingEditor,
            reason: "categoryTransactionsWindowEditor"
        )
    }

    private var filteredTransactions: [BWTransaction] {
        sortedTransactions(category?.transactions.filter(matchesFilters) ?? [])
    }

    private var transactionDateRange: (oldest: Date, newest: Date) {
        let dates = category?.transactions.map(\.date) ?? []
        let now = Date()

        return (
            oldest: dates.min() ?? now,
            newest: dates.max() ?? now
        )
    }

    var body: some View {
        Group {
            if let category {
                transactionTable(category: category)
            }
            else {
                ContentUnavailableView(
                    "Category Not Found",
                    systemImage: "folder.badge.questionmark"
                )
            }
        }
        .navigationTitle(title)
        .searchable(text: $searchText, placement: .toolbar, prompt: "Search transactions")
        .onAppear {
            resetFilters()
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    isCreatingTransaction = true
                } label: {
                    Label("Add Transaction", systemImage: "plus")
                }
                .help("Add Transaction")
                .disabled(category == nil)

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
        .onChange(of: filteredTransactions.map(\.id)) { _, ids in
            if let selection, !ids.contains(selection) {
                self.selection = nil
            }
        }
        .inspector(isPresented: .constant(true)) {
            if
                let transaction = filteredTransactions.first(where: { $0.id == selection }),
                category != nil
            {
                BWTransactionInspectorView(
                    categoryID: value.categoryID,
                    transaction: transaction,
                    deleteTransaction: {
                        Task(priority: .userInitiated) {
                            await store.deleteTransaction(
                                categoryID: value.categoryID,
                                transactionID: transaction.id,
                                windowStore: windowStore
                            )
                            selection = nil
                        }
                    },
                    saveTransaction: { updatedTransaction in
                        Task(priority: .userInitiated) {
                            _ = await store.updateTransaction(
                                categoryID: value.categoryID,
                                transaction: updatedTransaction,
                                windowStore: windowStore
                            )
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
            BWCreateCategoryTransactionView(
                categoryID: value.categoryID,
                onClose: {
                    isCreatingTransaction = false
                }
            )
            .environmentObject(store)
            .environmentObject(windowStore)
            .frame(minWidth: 420)
        }
        .alert("Error", isPresented: $windowStore.isErrorState) {
            Button("OK") {
                windowStore.clearError()
            }
        } message: {
            Text(windowStore.errorMessage)
        }
        .onAppear {
            updateAutoRefreshEditorBlocker()
        }
        .onDisappear {
            store.setAutoRefreshSuspended(false, reason: "categoryTransactionsWindowEditor")
        }
        .onChange(of: isCreatingTransaction) { _, _ in
            updateAutoRefreshEditorBlocker()
        }
        .onChange(of: isFilterPresented) { _, _ in
            updateAutoRefreshEditorBlocker()
        }
        .onChange(of: windowStore.isErrorState) { _, _ in
            updateAutoRefreshEditorBlocker()
        }
    }

    private func transactionTable(category: BWCategory) -> some View {
        Group {
            if category.transactions.isEmpty {
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
                    TableColumn("Date", value: \.date) { transaction in
                        Text(transaction.date.formatted(date: .abbreviated, time: .omitted))
                            .monospacedDigit()
                    }
                    .width(110)

                    TableColumn("Title", value: \.title) { transaction in
                        Text(transaction.title)
                            .lineLimit(1)
                    }

                    TableColumn("Description", value: \.description) { transaction in
                        Text(transaction.description.isEmpty ? " " : transaction.description)
                            .lineLimit(1)
                    }

                    TableColumn("Amount", value: \.amount) { transaction in
                        Text(transaction.amount.formattedMoneyAmount(currency: store.selectedCurrency))
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

    private func matchesFilters(_ transaction: BWTransaction) -> Bool {
        matchesSearch(transaction) &&
            matchesDateFilters(transaction) &&
            matchesAmountFilters(transaction)
    }

    private func matchesSearch(_ transaction: BWTransaction) -> Bool {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !query.isEmpty else {
            return true
        }

        let haystack = [
            transaction.title,
            transaction.description,
            transaction.date.formatted(date: .abbreviated, time: .omitted),
            transaction.amount.formattedMoneyAmount(currency: store.selectedCurrency),
            transaction.amount.moneyInputText
        ].joined(separator: " ")

        return haystack.localizedCaseInsensitiveContains(query)
    }

    private func matchesDateFilters(_ transaction: BWTransaction) -> Bool {
        guard isDateFilterEnabled else {
            return true
        }

        let calendar = Calendar.current
        let transactionDay = calendar.startOfDay(for: transaction.date)
        let startDay = calendar.startOfDay(for: startDate)
        let endDay = calendar.startOfDay(for: endDate)

        guard transactionDay >= startDay && transactionDay <= endDay else {
            return false
        }

        return true
    }

    private func matchesAmountFilters(_ transaction: BWTransaction) -> Bool {
        if !minimumAmount.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let minimumAmount = UInt64.parseMoneyAmount(minimumAmount) else {
                return false
            }

            guard transaction.amount >= minimumAmount else {
                return false
            }
        }

        if !maximumAmount.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let maximumAmount = UInt64.parseMoneyAmount(maximumAmount) else {
                return false
            }

            guard transaction.amount <= maximumAmount else {
                return false
            }
        }

        return true
    }

    private func sortedTransactions(_ transactions: [BWTransaction]) -> [BWTransaction] {
        transactions.sorted(using: sortOrder)
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

private struct BWCreateCategoryTransactionView: View {
    @EnvironmentObject var store: BWStore
    @EnvironmentObject var windowStore: BWWindowStore

    let categoryID: UUID
    let onClose: () -> Void

    @State private var title = ""
    @State private var amount = ""
    @State private var description = ""
    @State private var date = Date()
    @State private var isShowingDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Transaction")
                .font(.headline)

            VStack(alignment: .leading, spacing: 12) {
                field("Title") {
                    TextField("Title", text: $title, prompt: Text("Groceries at supermarket"))
                }

                field("Amount") {
                    HStack(spacing: 8) {
                        TextField("Amount", text: $amount, prompt: Text("0.00"))
                            .textFieldStyle(.roundedBorder)
                            .foregroundStyle(parsedAmount == nil && !amount.isEmpty ? .red : .primary)

                        Text(store.selectedCurrency.symbol)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                Button {
                    isShowingDetails.toggle()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .rotationEffect(.degrees(isShowingDetails ? 90 : 0))

                        Text("More Details")

                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if isShowingDetails {
                    VStack(alignment: .leading, spacing: 12) {
                        field("Description") {
                            TextField("Description", text: $description, prompt: Text("Add a note"))
                        }

                        field("Date") {
                            DatePicker(
                                "Date",
                                selection: $date,
                                displayedComponents: .date
                            )
                            .labelsHidden()
                        }
                    }
                    .padding(.top, 8)
                }
            }

            HStack {
                Spacer()

                Button("Cancel", role: .cancel) {
                    onClose()
                }

                Button("Save") {
                    Task(priority: .userInitiated) {
                        guard let parsedAmount else {
                            return
                        }

                        if await store.createTransaction(
                            categoryID: categoryID,
                            title: trimmedTitle,
                            description: trimmedDescription,
                            date: date,
                            amount: parsedAmount,
                            windowStore: windowStore
                        ) {
                            onClose()
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
            }
        }
        .padding(20)
    }

    private func field<Content: View>(
        _ title: Swift.String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)

            content()
        }
    }

    private var isValid: Bool {
        guard let parsedAmount else {
            return false
        }

        return !trimmedTitle.isEmpty && parsedAmount > 0
    }

    private var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedDescription: String {
        description.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var parsedAmount: UInt64? {
        UInt64.parseMoneyAmount(amount)
    }
}

struct BWTransactionInspectorView: View {
    let categoryID: UUID
    let categories: [BWCategory]
    let transaction: BWTransaction
    let deleteTransaction: () -> Void
    let saveTransaction: (BWTransaction) -> Void
    let saveCategory: ((UUID) -> Void)?

    @State private var title = ""
    @State private var amount = ""
    @State private var description = ""
    @State private var date = Date()
    @State private var selectedCategoryID: UUID?
    @State private var isDeleteConfirmationPresented = false
    @FocusState private var focusedField: Field?

    init(
        categoryID: UUID,
        categories: [BWCategory] = [],
        transaction: BWTransaction,
        deleteTransaction: @escaping () -> Void,
        saveTransaction: @escaping (BWTransaction) -> Void,
        saveCategory: ((UUID) -> Void)? = nil
    ) {
        self.categoryID = categoryID
        self.categories = categories
        self.transaction = transaction
        self.deleteTransaction = deleteTransaction
        self.saveTransaction = saveTransaction
        self.saveCategory = saveCategory
    }

    private enum Field: Hashable {
        case title
        case amount
        case description
    }

    var body: some View {
        VStack {
            Form {
                if saveCategory != nil {
                    Picker("Category", selection: $selectedCategoryID) {
                        ForEach(BWCategoryType.allCases, id: \.self) { type in
                            let categories = orderedCategories(for: type)

                            if !categories.isEmpty {
                                Text(type.title)
                                    .font(.headline)
                                    .selectionDisabled(true)

                                ForEach(categories) { category in
                                    Text(category.title)
                                        .tag(Optional(category.id))
                                }
                            }
                        }
                    }
                    .onChange(of: selectedCategoryID) { oldValue, newValue in
                        guard
                            oldValue != nil,
                            let newValue,
                            newValue != categoryID
                        else {
                            return
                        }

                        saveIfValid()
                        saveCategory?(newValue)
                    }
                }

                TextField("Title", text: $title)
                    .focused($focusedField, equals: .title)
                    .onSubmit {
                        saveIfValid()
                    }

                TextField("Amount", text: $amount, prompt: Text("0.00"))
                    .foregroundStyle(parsedAmount == nil ? .red : .primary)
                    .focused($focusedField, equals: .amount)
                    .monospacedDigit()
                    .onSubmit {
                        saveIfValid()
                    }

                TextField("Description", text: $description, prompt: Text("Add a note"))
                    .focused($focusedField, equals: .description)
                    .onSubmit {
                        saveIfValid()
                    }

                DatePicker(
                    "Date",
                    selection: $date,
                    displayedComponents: .date
                )
                .onChange(of: date) { _, _ in
                    saveIfValid()
                }

                Button(role: .destructive) {
                    isDeleteConfirmationPresented = true
                } label: {
                    Label("Delete Transaction", systemImage: "trash")
                }
            }
        }
        .onAppear {
            resetFields()
        }
        .onChange(of: focusedField) { oldValue, _ in
            if oldValue != nil {
                saveIfValid()
            }
        }
        .onChange(of: transaction.id) { _, _ in
            resetFields()
        }
        .onChange(of: categoryID) { _, _ in
            selectedCategoryID = categoryID
        }
        .onDisappear {
            saveIfValid()
        }
        .confirmationDialog(
            "Delete \(transaction.title)?",
            isPresented: $isDeleteConfirmationPresented
        ) {
            Button("Delete Transaction", role: .destructive) {
                deleteTransaction()
            }

            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will remove the transaction from the category.")
        }
    }

    private var parsedAmount: UInt64? {
        UInt64.parseMoneyAmount(amount)
    }

    private var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedDescription: String {
        description.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func orderedCategories(for type: BWCategoryType) -> [BWCategory] {
        BWBudget(title: "", categories: categories).orderedCategories(for: type)
    }

    private func resetFields() {
        title = transaction.title
        amount = transaction.amount.moneyInputText
        description = transaction.description
        date = transaction.date
        selectedCategoryID = categoryID
    }

    private func saveIfValid() {
        guard let parsedAmount, parsedAmount > 0, !trimmedTitle.isEmpty else {
            return
        }

        saveTransaction(BWTransaction(
            id: transaction.id,
            title: trimmedTitle,
            description: trimmedDescription,
            date: date,
            amount: parsedAmount
        ))
    }
}
