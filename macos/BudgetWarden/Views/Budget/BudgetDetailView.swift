import SwiftUI

struct BudgetDetailView: View {
    let budgets: [BudgetDocument]
    let budget: BudgetDocument
    let currency: AppCurrency
    let selectedBudgetID: BudgetDocument.ID?
    let onCreateBudget: () -> Void
    let onSelectBudget: (BudgetDocument) -> Void
    let onAddCategory: (Swift.String, UInt64, UInt64, BudgetCategoryType) -> Void
    let onUpdateCategory: (CategoryUpdate) -> Void
    let onRemoveCategory: (BudgetCategory) -> Void
    let onReorderCategories: (BudgetCategoryType, [Int]) -> Void
    let onAddTransaction: (TransactionDraft) -> Void

    @State private var isCreatingTransaction = false
    @State private var transactionCategoryID: Int?
    @State private var isReportingExpanded = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ForEach(BudgetCategoryType.allCases) { type in
                    categoryList(for: type)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle("Budget")
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
                
                Button {
                    transactionCategoryID = nil
                    isCreatingTransaction = true
                } label: {
                    Text("Transaction")
                    Image(systemName: "plus")
                }
                .help("Add Transaction")
                .disabled(budget.categories.isEmpty)
            }
            
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    isReportingExpanded.toggle()
                } label: {
                    Image(systemName: isReportingExpanded ? "sidebar.right" : "chart.bar.xaxis")
                }
                .help(isReportingExpanded ? "Hide Reporting" : "Show Reporting")
            }
        }
        .inspector(isPresented: $isReportingExpanded) {
            BudgetReportingView(
                budget: budget,
                currency: currency,
                isExpanded: $isReportingExpanded,
                scope: .inspector
            )
            .inspectorColumnWidth(min: 300, ideal: 340, max: 420)
        }
        .sheet(isPresented: $isCreatingTransaction) {
            CreateTransactionView(
                categories: budget.categories,
                initialCategoryID: transactionCategoryID,
                onSave: { draft in
                    onAddTransaction(draft)
                    isCreatingTransaction = false
                    transactionCategoryID = nil
                },
                onCancel: {
                    isCreatingTransaction = false
                    transactionCategoryID = nil
                }
            )
            .frame(minWidth: 420)
        }
    }

    private func categoryList(for type: BudgetCategoryType) -> some View {
        CategoryListView(
            type: type,
            categories: budget.categories(for: type),
            currency: currency
        ) { title, amountPlanned, amountAccumulated in
            onAddCategory(title, amountPlanned, amountAccumulated, type)
        } onUpdateCategory: { update in
            onUpdateCategory(update)
        } onRemoveCategory: { category in
            onRemoveCategory(category)
        } onReorderCategories: { orderedCategoryIDs in
            onReorderCategories(type, orderedCategoryIDs)
        } onAddTransaction: { category in
            transactionCategoryID = category.coreID
            isCreatingTransaction = true
        }
    }
}

struct CreateTransactionView: View {
    let categories: [BudgetCategory]
    let onSave: (TransactionDraft) -> Void
    let onCancel: () -> Void

    @State private var title = ""
    @State private var description = ""
    @State private var amount = ""
    @State private var date = Date()
    @State private var isShowingDetails = false
    @State private var selectedCategoryID: Int

    init(
        categories: [BudgetCategory],
        initialCategoryID: Int? = nil,
        onSave: @escaping (TransactionDraft) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.categories = categories
        self.onSave = onSave
        self.onCancel = onCancel
        _selectedCategoryID = State(initialValue: initialCategoryID ?? categories.first?.coreID ?? 0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Transaction")
                .font(.headline)

            VStack(alignment: .leading, spacing: 12) {
                field("Category") {
                    Picker("Category", selection: $selectedCategoryID) {
                        ForEach(BudgetCategoryType.allCases) { type in
                            Text(type.title)
                                .font(.headline)
                                .disabled(true)

                            ForEach(categories(for: type)) { category in
                                Text(category.title)
                                    .tag(category.coreID)
                            }
                        }
                    }
                    .labelsHidden()
                }

                field("Title") {
                    TextField("Title", text: $title)
                        .accessibilityIdentifier("transaction-title-field")
                }

                field("Amount") {
                    TextField("Amount", text: $amount)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("transaction-amount-field")
                }

                DisclosureGroup("More Details", isExpanded: $isShowingDetails) {
                    VStack(alignment: .leading, spacing: 12) {
                        field("Description") {
                            TextField("Description", text: $description)
                                .accessibilityIdentifier("transaction-description-field")
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
                    onCancel()
                }

                Button("Save") {
                    if let draft {
                        onSave(draft)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(draft == nil)
            }
        }
        .padding()
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

    private var draft: TransactionDraft? {
        guard
            !trimmedTitle.isEmpty,
            let parsedAmount,
            parsedAmount > 0,
            let transactionDate
        else {
            return nil
        }

        return TransactionDraft(
            categoryID: selectedCategoryID,
            title: trimmedTitle,
            description: trimmedDescription,
            date: transactionDate,
            amount: parsedAmount
        )
    }

    private var trimmedTitle: Swift.String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedDescription: Swift.String {
        description.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var parsedAmount: UInt64? {
        UInt64.parseMoneyAmount(amount)
    }

    private func categories(for type: BudgetCategoryType) -> [BudgetCategory] {
        categories
            .filter { $0.type == type }
            .sorted {
                if $0.ordinal != $1.ordinal {
                    return $0.ordinal < $1.ordinal
                }

                return $0.coreID < $1.coreID
            }
    }

    private var transactionDate: BWDate? {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: date)

        guard
            let year = components.year,
            let month = components.month,
            let day = components.day
        else {
            return nil
        }

        var bwDate = BWDate()

        guard bw_date_init(&bwDate, Int32(year), Int32(month), Int32(day)) == 0 else {
            return nil
        }

        return bwDate
    }
}
