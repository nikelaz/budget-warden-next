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

struct TransactionsView: View {
    @ObservedObject var store: BudgetStore
    let budgets: [BudgetRow]
    let budget: BudgetRow
    let currency: AppCurrency
    let selectedBudgetURL: URL?
    let onCreateBudget: () -> Void
    let onSelectBudget: (BudgetRow) -> Void
    let onAddTransaction: (TransactionDraft) -> Void
    let onUpdateTransaction: (TransactionUpdate) -> Void
    let onRemoveTransaction: (Int) -> Void

    @State private var isCreatingTransaction = false
    @State private var searchText = ""
    @State private var selectedCategoryType: BudgetCategoryType?
    @State private var selectedCategoryID: Int?
    @State private var editingCell: TransactionEditingCell?
    @State private var editedText = ""
    @State private var datePickerTransactionID: Int?
    @State private var pendingDate = Date()
    @State private var checkedTransactionIDs = Set<Int>()
    @State private var transactionsPendingRemoval: [Int] = []
    @FocusState private var focusedEditingCell: TransactionEditingCell?

    private var categoryIDs: [Int] {
        store.categoryIDs(in: budget.url)
    }

    private var transactionIDs: [Int] {
        store.transactionIDs(in: budget.url)
    }

    private var filteredTransactionIDs: [Int] {
        transactionIDs.filter { transactionID in
            guard let transaction = store.transaction(transactionID, in: budget.url) else {
                return false
            }

            return matchesCategoryType(transaction) &&
                matchesCategory(transaction) &&
                matchesSearch(transaction)
        }
    }

    var body: some View {
        Group {
            if transactionIDs.isEmpty {
                ContentUnavailableView(
                    "No Transactions",
                    systemImage: "list.bullet.rectangle"
                )
            } else if filteredTransactionIDs.isEmpty {
                ContentUnavailableView.search(text: searchText)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        transactionHeader

                        ForEach(filteredTransactionIDs, id: \.self) { transactionID in
                            transactionRow(transactionID)
                            Divider()
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
            }
        }
        .navigationTitle("Transactions")
        .searchable(text: $searchText, placement: .toolbar, prompt: "Search transactions")
        .onExitCommand {
            discardEdit()
        }
        .onDeleteCommand {
            requestRemoveCheckedTransactions()
        }
        .onChange(of: focusedEditingCell) { _, newFocusedCell in
            guard let editingCell, newFocusedCell != editingCell else {
                return
            }

            commitActiveEdit()
        }
        .toolbar {
            ToolbarItemGroup(placement: .principal) {
                Menu {
                    ForEach(budgets) { budget in
                        Button {
                            onSelectBudget(budget)
                        } label: {
                            if selectedBudgetURL?.standardizedFileURL == budget.url.standardizedFileURL {
                                Label(budget.title, systemImage: "checkmark")
                            } else {
                                Text(budget.title)
                            }
                        }
                    }

                    Divider()

                    Button {
                        onCreateBudget()
                    } label: {
                        Label("New Budget", systemImage: "plus")
                    }
                } label: {
                    Text(budget.title)
                }
                .accessibilityIdentifier("budget-menu")
            }

            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    isCreatingTransaction = true
                } label: {
                    Label("Add Transaction", systemImage: "plus")
                }
                .help("Add Transaction")
                .accessibilityIdentifier("transactions-add-transaction-button")
                .disabled(categoryIDs.isEmpty)

                if !checkedTransactionIDs.isEmpty {
                    Button(role: .destructive) {
                        requestRemoveCheckedTransactions()
                    } label: {
                        Label("Delete Selected", systemImage: "trash")
                    }
                    .help("Delete Selected Transactions")
                    .accessibilityIdentifier("transactions-delete-selected-button")
                }

                Menu {
                    Picker("Category Type", selection: $selectedCategoryType) {
                        Text("All Types").tag(nil as BudgetCategoryType?)

                        ForEach(BudgetCategoryType.allCases) { type in
                            Text(type.title).tag(type as BudgetCategoryType?)
                        }
                    }
                    Picker("Category", selection: $selectedCategoryID) {
                        Text("All Categories").tag(nil as Int?)

                        ForEach(BudgetCategoryType.allCases) { type in
                            Section(type.title) {
                                ForEach(store.categoryIDs(for: type, in: budget.url), id: \.self) { categoryID in
                                    Text(categoryTitle(categoryID)).tag(categoryID as Int?)
                                }
                            }
                        }
                    }
                } label: {
                    Label("Filters", systemImage: "line.3.horizontal.decrease.circle")
                }
                .accessibilityIdentifier("transactions-filter-menu")
            }
        }
        .sheet(isPresented: $isCreatingTransaction) {
            CreateTransactionView(
                store: store,
                budgetURL: budget.url,
                onSave: { draft in
                    onAddTransaction(draft)
                    isCreatingTransaction = false
                },
                onCancel: {
                    isCreatingTransaction = false
                }
            )
            .frame(minWidth: 420)
        }
        .confirmationDialog(
            "Delete Transactions?",
            isPresented: removeTransactionsConfirmationBinding
        ) {
            Button("Delete \(transactionsPendingRemoval.count) Transaction\(transactionsPendingRemoval.count == 1 ? "" : "s")", role: .destructive) {
                removePendingTransactions()
            }

            Button("Cancel", role: .cancel) {
                transactionsPendingRemoval = []
            }
        } message: {
            Text("You are about to delete \(transactionsPendingRemoval.count) transaction\(transactionsPendingRemoval.count == 1 ? "" : "s").")
        }
    }
}

private extension TransactionsView {
    var transactionHeader: some View {
        return HStack(spacing: 12) {
            Text("")
                .frame(width: 34)
            headerText("Date")
                .frame(width: 110, alignment: .leading)
            headerText("Title")
                .frame(minWidth: 160, idealWidth: 220, maxWidth: .infinity, alignment: .leading)
            headerText("Description")
                .frame(minWidth: 180, idealWidth: 260, maxWidth: .infinity, alignment: .leading)
            headerText("Category")
                .frame(width: 150, alignment: .leading)
            headerText("Type")
                .frame(width: 100, alignment: .leading)
            headerText("Amount")
                .frame(width: 110, alignment: .trailing)
        }
        .padding(.vertical, 6)
    }

    func headerText(_ title: Swift.String) -> some View {
        Text(title)
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundStyle(.secondary)
    }

    func transactionRow(_ transactionID: Int) -> some View {
        let transaction = store.transaction(transactionID, in: budget.url)

        return HStack(spacing: 12) {
            Toggle("", isOn: checkedBinding(for: transactionID))
                .labelsHidden()
                .frame(width: 34)

            dateCell(for: transactionID, transaction: transaction)
                .frame(width: 110, alignment: .leading)

            textCell(
                for: transactionID,
                cell: .title(transactionID),
                text: transaction?.title.swiftString() ?? ""
            )
            .frame(minWidth: 160, idealWidth: 220, maxWidth: .infinity, alignment: .leading)

            textCell(
                for: transactionID,
                cell: .description(transactionID),
                text: transaction?.description.swiftString() ?? ""
            )
            .frame(minWidth: 180, idealWidth: 260, maxWidth: .infinity, alignment: .leading)

            categoryMenuCell(
                for: transactionID,
                transaction: transaction,
                title: transaction?.category_title.swiftString() ?? ""
            )
                .frame(width: 150, alignment: .leading)

            categoryMenuCell(
                for: transactionID,
                transaction: transaction,
                title: transaction?.categoryType?.title ?? ""
            )
            .frame(width: 100, alignment: .leading)

            amountCell(for: transactionID, transaction: transaction)
                .frame(width: 110, alignment: .trailing)
        }
        .padding(.vertical, 5)
    }

    var removeTransactionsConfirmationBinding: Binding<Bool> {
        Binding {
            !transactionsPendingRemoval.isEmpty
        } set: { isPresented in
            if !isPresented {
                transactionsPendingRemoval = []
            }
        }
    }

    func tableText(
        _ text: Swift.String,
        transactionID: Int,
        alignment: Alignment = .leading,
        accessibilityIdentifier: Swift.String? = nil
    ) -> some View {
        Text(text.isEmpty ? " " : text)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: alignment)
            .contentShape(.rect)
            .accessibilityIdentifier(accessibilityIdentifier ?? "transaction-\(transactionID)-cell")
            .contextMenu {
                Button(role: .destructive) {
                    if checkedTransactionIDs.contains(transactionID), checkedTransactionIDs.count > 1 {
                        requestRemoveCheckedTransactions()
                    } else {
                        requestRemoveTransactions([transactionID])
                    }
                } label: {
                    Label(
                        checkedTransactionIDs.contains(transactionID) && checkedTransactionIDs.count > 1
                            ? "Delete Selected Transactions"
                            : "Delete Transaction",
                        systemImage: "trash"
                    )
                }
            }
    }

    func checkedBinding(for transactionID: Int) -> Binding<Bool> {
        Binding {
            checkedTransactionIDs.contains(transactionID)
        } set: { isChecked in
            if isChecked {
                checkedTransactionIDs.insert(transactionID)
            } else {
                checkedTransactionIDs.remove(transactionID)
            }
        }
    }

    func textCell(for transactionID: Int, cell: TransactionEditingCell, text: Swift.String) -> some View {
        Group {
            if editingCell == cell {
                TextField("", text: $editedText)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("transaction-\(cell.transactionID)-edit-field")
                    .focused($focusedEditingCell, equals: cell)
                    .background {
                        OutsideClickCommitObserver {
                            commitActiveEdit()
                        }
                    }
                    .onAppear {
                        focusEditingCell(cell)
                    }
                    .onSubmit {
                        commitActiveEdit()
                    }
                    .onExitCommand {
                        discardEdit()
                    }
            } else {
                tableText(text, transactionID: transactionID)
                    .onTapGesture {
                        startEditing(cell, text: text)
                    }
            }
        }
    }

    func amountCell(for transactionID: Int, transaction: BWTransactionView?) -> some View {
        let cell = TransactionEditingCell.amount(transactionID)
        let title = transaction?.title.swiftString() ?? ""
        let amount = transaction?.amount ?? 0

        return Group {
            if editingCell == cell {
                TextField("", text: $editedText)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .accessibilityIdentifier("transaction-\(transactionID)-amount-edit-field")
                    .focused($focusedEditingCell, equals: cell)
                    .background {
                        OutsideClickCommitObserver {
                            commitActiveEdit()
                        }
                    }
                    .onAppear {
                        focusEditingCell(cell)
                    }
                    .onSubmit {
                        commitActiveEdit()
                    }
                    .onExitCommand {
                        discardEdit()
                    }
            } else {
                tableText(
                    amount.formattedMoneyAmount(currency: currency),
                    transactionID: transactionID,
                    alignment: .trailing,
                    accessibilityIdentifier: "transaction-amount-cell-\(title.accessibilityIdentifierComponent)"
                )
                .monospacedDigit()
                .onTapGesture {
                    startEditing(cell, text: amount.moneyAmountInputText)
                }
            }
        }
    }

    func dateCell(for transactionID: Int, transaction: BWTransactionView?) -> some View {
        let date = transaction?.date ?? BWDate()

        return Button {
            discardEdit()
            pendingDate = date.dateValue
            datePickerTransactionID = transactionID
        } label: {
            tableText(
                date.formattedDate,
                transactionID: transactionID
            )
            .monospacedDigit()
        }
        .buttonStyle(.plain)
        .popover(isPresented: datePickerPresentationBinding(for: transactionID)) {
            VStack(alignment: .leading, spacing: 12) {
                DatePicker("Date", selection: $pendingDate, displayedComponents: .date)
                    .labelsHidden()
                    .datePickerStyle(.graphical)
                    .frame(width: 190)

                HStack {
                    Spacer()

                    Button("Cancel") {
                        datePickerTransactionID = nil
                    }

                    Button("Save") {
                        savePendingDate(for: transactionID)
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding()
            .frame(width: 190)
        }
    }

    func categoryMenuCell(for transactionID: Int, transaction: BWTransactionView?, title: Swift.String) -> some View {
        Menu {
            ForEach(BudgetCategoryType.allCases) { type in
                Section(type.title) {
                    ForEach(store.categoryIDs(for: type, in: budget.url), id: \.self) { categoryID in
                        Button {
                            commit(update(for: transactionID, categoryID: categoryID))
                        } label: {
                            let title = categoryTitle(categoryID)

                            if categoryID == transaction?.categoryID {
                                Label(title, systemImage: "checkmark")
                            } else {
                                Text(title)
                            }
                        }
                    }
                }
            }
        } label: {
            tableText(title, transactionID: transactionID)
        }
        .menuStyle(.borderlessButton)
        .buttonStyle(.plain)
    }

    func requestRemoveCheckedTransactions() {
        let transactionIDs = transactionIDs.filter { checkedTransactionIDs.contains($0) }

        guard !transactionIDs.isEmpty else {
            return
        }

        requestRemoveTransactions(transactionIDs)
    }

    func requestRemoveTransactions(_ transactionIDs: [Int]) {
        guard !transactionIDs.isEmpty else {
            return
        }

        discardEdit()
        transactionsPendingRemoval = transactionIDs
    }

    func removePendingTransactions() {
        let transactionIDs = transactionsPendingRemoval
        checkedTransactionIDs.subtract(transactionIDs)
        transactionsPendingRemoval = []

        for transactionID in transactionIDs {
            onRemoveTransaction(transactionID)
        }
    }

    func datePickerPresentationBinding(for transactionID: Int) -> Binding<Bool> {
        Binding {
            datePickerTransactionID == transactionID
        } set: { isPresented in
            if !isPresented, datePickerTransactionID == transactionID {
                datePickerTransactionID = nil
            }
        }
    }

    func savePendingDate(for transactionID: Int) {
        guard let date = BWDate(date: pendingDate) else {
            datePickerTransactionID = nil
            return
        }

        commit(update(for: transactionID, date: date))
        datePickerTransactionID = nil
    }

    func startEditing(_ cell: TransactionEditingCell, text: Swift.String = "") {
        if editingCell != nil, editingCell != cell {
            commitActiveEdit()
        }

        editingCell = cell
        editedText = text
        focusEditingCell(cell)
    }

    func focusEditingCell(_ cell: TransactionEditingCell) {
        DispatchQueue.main.async {
            focusedEditingCell = cell
        }
    }

    func commitActiveEdit() {
        guard
            let editingCell,
            transactionIDs.contains(editingCell.transactionID)
        else {
            discardEdit()
            return
        }

        switch editingCell {
        case .title:
            let title = editedText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else {
                discardEdit()
                return
            }

            commit(update(for: editingCell.transactionID, title: title))
        case .description:
            commit(update(for: editingCell.transactionID, description: editedText.trimmingCharacters(in: .whitespacesAndNewlines)))
        case .amount:
            guard let amount = UInt64.parseMoneyAmount(editedText) else {
                discardEdit()
                return
            }

            commit(update(for: editingCell.transactionID, amount: amount))
        }
    }

    func commit(_ update: TransactionUpdate) {
        onUpdateTransaction(update)
        discardEdit()
    }

    func discardEdit() {
        editingCell = nil
        editedText = ""
        focusedEditingCell = nil
    }

    func update(
        for transactionID: Int,
        categoryID: Int? = nil,
        title: Swift.String? = nil,
        description: Swift.String? = nil,
        date: BWDate? = nil,
        amount: UInt64? = nil
    ) -> TransactionUpdate {
        let transaction = store.transaction(transactionID, in: budget.url)

        return TransactionUpdate(
            transactionID: transactionID,
            categoryID: categoryID ?? transaction?.categoryID ?? 0,
            title: title ?? transaction?.title.swiftString() ?? "",
            description: description ?? transaction?.description.swiftString() ?? "",
            date: date ?? transaction?.date ?? BWDate(),
            amount: amount ?? transaction?.amount ?? 0
        )
    }

    func matchesCategoryType(_ transaction: BWTransactionView) -> Bool {
        selectedCategoryType.map { transaction.categoryType == $0 } ?? true
    }

    func matchesCategory(_ transaction: BWTransactionView) -> Bool {
        selectedCategoryID.map { transaction.categoryID == $0 } ?? true
    }

    func matchesSearch(_ transaction: BWTransactionView) -> Bool {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !query.isEmpty else {
            return true
        }

        let amount = transaction.amount
        let haystack = [
            transaction.title.swiftString(),
            transaction.description.swiftString(),
            transaction.date.formattedDate,
            transaction.category_title.swiftString(),
            transaction.categoryType?.title ?? "",
            amount.formattedMoneyAmount(currency: currency),
            amount.moneyAmountInputText
        ].joined(separator: " ")

        return haystack.localizedCaseInsensitiveContains(query)
    }

    func categoryTitle(_ categoryID: Int) -> Swift.String {
        store.category(categoryID, in: budget.url)?.title.swiftString() ?? ""
    }
}

private enum TransactionEditingCell: Hashable {
    case title(Int)
    case description(Int)
    case amount(Int)

    var transactionID: Int {
        switch self {
        case .title(let transactionID),
             .description(let transactionID),
             .amount(let transactionID):
            return transactionID
        }
    }
}

private extension BWDate {
    var dateValue: Date {
        DateComponents(
            calendar: .current,
            year: Int(year),
            month: Int(month),
            day: Int(day)
        ).date ?? Date()
    }

    init?(date: Date) {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: date)

        guard
            let year = components.year,
            let month = components.month,
            let day = components.day
        else {
            return nil
        }

        self.init()

        guard bw_date_init(&self, Int32(year), Int32(month), Int32(day)) == 0 else {
            return nil
        }
    }
}

private extension Swift.String {
    var accessibilityIdentifierComponent: Swift.String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalars = unicodeScalars.map { scalar in
            allowed.contains(scalar) ? Character(scalar) : "-"
        }

        return Swift.String(scalars)
    }
}
