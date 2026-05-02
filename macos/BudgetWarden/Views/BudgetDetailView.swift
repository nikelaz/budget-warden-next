import AppKit
import Charts
import SwiftUI

struct BudgetDetailView: View {
    let budgets: [BudgetDocument]
    let budget: BudgetDocument
    @Binding var selectedBudgetID: BudgetDocument.ID?
    let onCreateBudget: () -> Void
    let onAddCategory: (Swift.String, UInt64, BudgetCategoryType) -> Void
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
            BudgetTopToolbar(
                budgets: budgets,
                selectedBudgetID: $selectedBudgetID,
                onCreateBudget: onCreateBudget
            )
            
            ToolbarItemGroup(placement: .principal) {
                Button {
                    isCreatingTransaction = true
                } label: {
                    Text("New Transaction")
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
                isExpanded: $isReportingExpanded
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
            categories: budget.categories(for: type)
        ) { title, amountPlanned in
            onAddCategory(title, amountPlanned, type)
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
                }

                field("Amount") {
                    TextField("Amount", text: $amount)
                        .textFieldStyle(.roundedBorder)
                }

                DisclosureGroup("More Details", isExpanded: $isShowingDetails) {
                    VStack(alignment: .leading, spacing: 12) {
                        field("Description") {
                            TextField("Description", text: $description)
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
        UInt64(amount.trimmingCharacters(in: .whitespacesAndNewlines))
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

private struct BudgetReportingView: View {
    let budget: BudgetDocument
    @Binding var isExpanded: Bool

    private var typeSummaries: [CategoryTypeSummary] {
        BudgetCategoryType.allCases.map { type in
            let categories = budget.categories(for: type)

            return CategoryTypeSummary(
                type: type,
                planned: categories.total(\.amountPlanned),
                actual: categories.total(\.amountActual),
                accumulated: categories.total(\.amountAccumulated)
            )
        }
    }

    private var topActualCategories: [BudgetCategory] {
        budget.categories
            .filter { $0.amountActual > 0 }
            .sorted { $0.amountActual > $1.amountActual }
            .prefix(6)
            .map { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Reporting", systemImage: "chart.pie")
                    .font(.headline)

                Spacer()

                Button {
                    isExpanded = false
                } label: {
                    Image(systemName: "sidebar.right")
                }
                .buttonStyle(.borderless)
                .help("Hide Reporting")
            }
            .padding(14)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    reportingMetricGrid

                    ReportChartSection(title: "Planned vs Actual") {
                        Chart(typeSummaries) { summary in
                            BarMark(
                                x: .value("Category", summary.type.title),
                                y: .value("Amount", summary.planned)
                            )
                            .foregroundStyle(by: .value("Measure", "Planned"))

                            BarMark(
                                x: .value("Category", summary.type.title),
                                y: .value("Amount", summary.actual)
                            )
                            .foregroundStyle(by: .value("Measure", "Actual"))
                        }
                        .chartLegend(position: .bottom, alignment: .leading)
                        .frame(height: 190)
                    }

                    ReportChartSection(title: "Actual by Category") {
                        if topActualCategories.isEmpty {
                            emptyChartState
                        } else {
                            Chart(topActualCategories) { category in
                                BarMark(
                                    x: .value("Actual", category.amountActual),
                                    y: .value("Category", category.title)
                                )
                                .foregroundStyle(by: .value("Type", category.type.title))
                            }
                            .chartLegend(position: .bottom, alignment: .leading)
                            .frame(height: 220)
                        }
                    }
                }
                .padding(14)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var reportingMetricGrid: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
            GridRow {
                ReportMetricView(title: "Planned", value: budget.categories.total(\.amountPlanned))
                ReportMetricView(title: "Actual", value: budget.categories.total(\.amountActual))
            }

            GridRow {
                ReportMetricView(title: "Saved", value: budget.categories(for: .savings).total(\.amountActual))
                ReportMetricView(title: "Debt", value: budget.categories(for: .debt).total(\.amountActual))
            }
        }
    }

    private var emptyChartState: some View {
        Text("No actual amounts yet")
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 160)
    }
}

private struct ReportChartSection<Content: View>: View {
    let title: Swift.String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline)
                .fontWeight(.semibold)

            content
                .padding(10)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }
}

private struct ReportMetricView: View {
    let title: Swift.String
    let value: UInt64

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(value.formatted())
                .font(.title3)
                .fontWeight(.semibold)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct CategoryTypeSummary: Identifiable {
    let type: BudgetCategoryType
    let planned: UInt64
    let actual: UInt64
    let accumulated: UInt64

    var id: BudgetCategoryType {
        type
    }
}

private extension Array where Element == BudgetCategory {
    func total(_ keyPath: KeyPath<BudgetCategory, UInt64>) -> UInt64 {
        reduce(0) { $0 + $1[keyPath: keyPath] }
    }
}
