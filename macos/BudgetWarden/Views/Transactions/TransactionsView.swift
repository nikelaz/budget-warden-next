import SwiftUI

struct TransactionsView: View {
    let budgets: [BudgetDocument]
    let budget: BudgetDocument
    let currency: AppCurrency
    let selectedBudgetID: BudgetDocument.ID?
    let onCreateBudget: () -> Void
    let onSelectBudget: (BudgetDocument) -> Void
    let onAddTransaction: (TransactionDraft) -> Void
    let onUpdateTransaction: (TransactionUpdate) -> Void
    let onRemoveTransaction: (BudgetTransaction) -> Void

    @State private var isCreatingTransaction = false
    @State private var searchText = ""
    @State private var selectedCategoryType: BudgetCategoryType?
    @State private var selectedCategoryID: Int?
    @State private var editingCell: TransactionEditingCell?
    @State private var editedText = ""
    @State private var datePickerTransactionID: Int?
    @State private var pendingDate = Date()
    @State private var checkedTransactionIDs = Set<BudgetTransaction.ID>()
    @State private var transactionsPendingRemoval: [BudgetTransaction] = []
    @FocusState private var focusedEditingCell: TransactionEditingCell?

    private var filteredTransactions: [BudgetTransaction] {
        budget.transactions.filter { transaction in
            matchesCategoryType(transaction) &&
                matchesCategory(transaction) &&
                matchesSearch(transaction)
        }
    }

    var body: some View {
        Group {
            if budget.transactions.isEmpty {
                ContentUnavailableView(
                    "No Transactions",
                    systemImage: "list.bullet.rectangle"
                )
            } else if filteredTransactions.isEmpty {
                ContentUnavailableView.search(text: searchText)
            } else {
                Table(filteredTransactions) {
                    TableColumn("") { transaction in
                        Toggle("", isOn: checkedBinding(for: transaction))
                            .labelsHidden()
                    }
                    .width(34)

                    TableColumn("Date") { transaction in
                        dateCell(for: transaction)
                    }
                    .width(min: 110, ideal: 120)

                    TableColumn("Title") { transaction in
                        textCell(for: transaction, cell: .title(transaction.coreID), text: transaction.title)
                    }
                    .width(min: 160, ideal: 220)

                    TableColumn("Description") { transaction in
                        textCell(for: transaction, cell: .description(transaction.coreID), text: transaction.description)
                    }
                    .width(min: 180, ideal: 260)

                    TableColumn("Category") { transaction in
                        categoryCell(for: transaction)
                    }
                    .width(min: 140, ideal: 180)

                    TableColumn("Type") { transaction in
                        categoryMenuCell(for: transaction, title: transaction.categoryType.title)
                    }
                    .width(min: 100, ideal: 120)

                    TableColumn("Amount") { transaction in
                        amountCell(for: transaction)
                    }
                    .width(min: 110, ideal: 130)
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
                            if selectedBudgetID == budget.id {
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
            }
            
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    isCreatingTransaction = true
                } label: {
                    Label("Add Transaction", systemImage: "plus")
                }
                .help("Add Transaction")
                .disabled(budget.categories.isEmpty)

                if !checkedTransactionIDs.isEmpty {
                    Button(role: .destructive) {
                        requestRemoveCheckedTransactions()
                    } label: {
                        Label("Delete Selected", systemImage: "trash")
                    }
                    .help("Delete Selected Transactions")
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
                                ForEach(budget.categories(for: type)) { category in
                                    Text(category.title).tag(category.coreID as Int?)
                                }
                            }
                        }
                    }
                } label: {
                    Label("Filters", systemImage: "line.3.horizontal.decrease.circle")
                }
            }
        }
        .sheet(isPresented: $isCreatingTransaction) {
            CreateTransactionView(
                categories: budget.categories,
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
    var removeTransactionsConfirmationBinding: Binding<Bool> {
        Binding {
            !transactionsPendingRemoval.isEmpty
        } set: { isPresented in
            if !isPresented {
                transactionsPendingRemoval = []
            }
        }
    }

    func tableText(_ text: Swift.String, transaction: BudgetTransaction, alignment: Alignment = .leading) -> some View {
        Text(text.isEmpty ? " " : text)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: alignment)
            .contentShape(.rect)
            .contextMenu {
                Button(role: .destructive) {
                    if checkedTransactionIDs.contains(transaction.id), checkedTransactionIDs.count > 1 {
                        requestRemoveCheckedTransactions()
                    } else {
                        requestRemoveTransactions([transaction])
                    }
                } label: {
                    Label(
                        checkedTransactionIDs.contains(transaction.id) && checkedTransactionIDs.count > 1
                            ? "Delete Selected Transactions"
                            : "Delete Transaction",
                        systemImage: "trash"
                    )
                }
            }
    }

    func checkedBinding(for transaction: BudgetTransaction) -> Binding<Bool> {
        Binding {
            checkedTransactionIDs.contains(transaction.id)
        } set: { isChecked in
            if isChecked {
                checkedTransactionIDs.insert(transaction.id)
            } else {
                checkedTransactionIDs.remove(transaction.id)
            }
        }
    }

    func textCell(for transaction: BudgetTransaction, cell: TransactionEditingCell, text: Swift.String) -> some View {
        Group {
            if editingCell == cell {
                TextField("", text: $editedText)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedEditingCell, equals: cell)
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
                tableText(text, transaction: transaction)
                    .onTapGesture {
                        startEditing(cell, text: text)
                    }
            }
        }
    }

    func amountCell(for transaction: BudgetTransaction) -> some View {
        let cell = TransactionEditingCell.amount(transaction.coreID)

        return Group {
            if editingCell == cell {
                TextField("", text: $editedText)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .focused($focusedEditingCell, equals: cell)
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
                    transaction.amount.formattedMoneyAmount(currency: currency),
                    transaction: transaction,
                    alignment: .trailing
                )
                .monospacedDigit()
                .onTapGesture {
                    startEditing(cell, text: transaction.amount.moneyAmountInputText)
                }
            }
        }
    }

    func dateCell(for transaction: BudgetTransaction) -> some View {
        Button {
            discardEdit()
            pendingDate = transaction.date.dateValue
            datePickerTransactionID = transaction.coreID
        } label: {
            tableText(transaction.formattedDate, transaction: transaction)
                .monospacedDigit()
        }
        .buttonStyle(.plain)
        .popover(isPresented: datePickerPresentationBinding(for: transaction)) {
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
                        savePendingDate(for: transaction)
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding()
            .frame(width: 190)
        }
    }

    func categoryCell(for transaction: BudgetTransaction) -> some View {
        categoryMenuCell(for: transaction, title: transaction.categoryTitle)
    }

    func categoryMenuCell(for transaction: BudgetTransaction, title: Swift.String) -> some View {
        Menu {
            ForEach(BudgetCategoryType.allCases) { type in
                Section(type.title) {
                    ForEach(budget.categories(for: type)) { category in
                        Button {
                            commit(update(for: transaction, categoryID: category.coreID))
                        } label: {
                            if category.coreID == transaction.categoryID {
                                Label(category.title, systemImage: "checkmark")
                            } else {
                                Text(category.title)
                            }
                        }
                    }
                }
            }
        } label: {
            tableText(title, transaction: transaction)
        }
        .menuStyle(.borderlessButton)
        .buttonStyle(.plain)
    }

    func requestRemoveCheckedTransactions() {
        let transactions = budget.transactions.filter { checkedTransactionIDs.contains($0.id) }

        guard !transactions.isEmpty else {
            return
        }

        requestRemoveTransactions(transactions)
    }

    func requestRemoveTransactions(_ transactions: [BudgetTransaction]) {
        guard !transactions.isEmpty else {
            return
        }

        discardEdit()
        transactionsPendingRemoval = transactions
    }

    func removePendingTransactions() {
        let transactions = transactionsPendingRemoval
        checkedTransactionIDs.subtract(transactions.map(\.id))
        transactionsPendingRemoval = []

        for transaction in transactions {
            onRemoveTransaction(transaction)
        }
    }

    func datePickerPresentationBinding(for transaction: BudgetTransaction) -> Binding<Bool> {
        Binding {
            datePickerTransactionID == transaction.coreID
        } set: { isPresented in
            if !isPresented, datePickerTransactionID == transaction.coreID {
                datePickerTransactionID = nil
            }
        }
    }

    func savePendingDate(for transaction: BudgetTransaction) {
        guard let date = BWDate(date: pendingDate) else {
            datePickerTransactionID = nil
            return
        }

        commit(update(for: transaction, date: date))
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
            let transaction = budget.transactions.first(where: { $0.coreID == editingCell.transactionID })
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

            commit(update(for: transaction, title: title))
        case .description:
            commit(update(for: transaction, description: editedText.trimmingCharacters(in: .whitespacesAndNewlines)))
        case .amount:
            guard let amount = UInt64.parseMoneyAmount(editedText) else {
                discardEdit()
                return
            }

            commit(update(for: transaction, amount: amount))
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
        for transaction: BudgetTransaction,
        categoryID: Int? = nil,
        title: Swift.String? = nil,
        description: Swift.String? = nil,
        date: BWDate? = nil,
        amount: UInt64? = nil
    ) -> TransactionUpdate {
        TransactionUpdate(
            transactionID: transaction.coreID,
            categoryID: categoryID ?? transaction.categoryID,
            title: title ?? transaction.title,
            description: description ?? transaction.description,
            date: date ?? transaction.date,
            amount: amount ?? transaction.amount
        )
    }

    func matchesCategoryType(_ transaction: BudgetTransaction) -> Bool {
        selectedCategoryType.map { transaction.categoryType == $0 } ?? true
    }

    func matchesCategory(_ transaction: BudgetTransaction) -> Bool {
        selectedCategoryID.map { transaction.categoryID == $0 } ?? true
    }

    func matchesSearch(_ transaction: BudgetTransaction) -> Bool {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !query.isEmpty else {
            return true
        }

        let haystack = [
            transaction.title,
            transaction.description,
            transaction.formattedDate,
            transaction.categoryTitle,
            transaction.categoryType.title,
            transaction.amount.formattedMoneyAmount(currency: currency),
            transaction.amount.moneyAmountInputText
        ].joined(separator: " ")

        return haystack.localizedCaseInsensitiveContains(query)
    }

    var selectedCategoryTitle: Swift.String {
        guard let selectedCategoryID else {
            return "All Categories"
        }

        return budget.categories.first(where: { $0.coreID == selectedCategoryID })?.title ?? "All Categories"
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
