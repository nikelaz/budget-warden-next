import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct CategoryListView: View {
    let type: BudgetCategoryType
    let categories: [BudgetCategory]
    let currency: AppCurrency
    let onAddCategory: (Swift.String, UInt64, UInt64) -> Void
    let onUpdateCategory: (CategoryUpdate) -> Void
    let onRemoveCategory: (BudgetCategory) -> Void
    let onReorderCategories: ([Int]) -> Void
    let onAddTransaction: (BudgetCategory) -> Void

    @State private var isCreatingCategory = false
    @State private var newCategoryTitle = ""
    @State private var newCategoryPlanned = "0"
    @State private var newCategoryAccumulated = "0"
    @State private var editingCell: EditingCell?
    @State private var editedValue = ""
    @State private var categoryPendingRemoval: BudgetCategory?
    @State private var draggedCategoryID: Int?
    @State private var dropTargetCategoryID: Int?
    @State private var isProgrammaticallyChangingEditingCell = false
    @FocusState private var focusedNewCategoryField: NewCategoryField?
    @FocusState private var focusedEditingCell: EditingCell?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerRow

            VStack(alignment: .leading, spacing: 0) {
                if categories.isEmpty && !isCreatingCategory {
                    emptyRow
                    Divider()
                } else {
                    ForEach(categories) { category in
                        dropIndicator(for: category)
                        categoryRow(category)
                        rowSeparator(for: category)
                    }
                }

                if isCreatingCategory {
                    newCategoryRow
                    Divider()
                }

                totalRow
            }
        }
        .padding(.horizontal, 10)
        .background(Color(nsColor: .quaternarySystemFill))
        .clipShape(.rect(cornerRadius: 8, style: .continuous))
        .confirmationDialog(
            "Delete Category?",
            isPresented: removeCategoryConfirmationBinding,
            presenting: categoryPendingRemoval
        ) { category in
            Button("Delete Category", role: .destructive) {
                onRemoveCategory(category)
                categoryPendingRemoval = nil
            }

            Button("Cancel", role: .cancel) {
                categoryPendingRemoval = nil
            }
        } message: { category in
            Text("Delete \(category.title)? This will also remove its transactions.")
        }
        .onChange(of: focusedEditingCell) { _, newFocusedCell in
            guard !isProgrammaticallyChangingEditingCell else {
                return
            }

            guard let editingCell, newFocusedCell != editingCell else {
                return
            }

            commitActiveEdit()
        }
    }
}

private extension CategoryListView {
    var removeCategoryConfirmationBinding: Binding<Bool> {
        Binding {
            categoryPendingRemoval != nil
        } set: { isPresented in
            if !isPresented {
                categoryPendingRemoval = nil
            }
        }
    }

    var headerRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(type.title)
                .font(.headline)
                .padding(.horizontal, 5)

            Spacer()

            ForEach(type.valueColumns) { column in
                Text(column.title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(5)
                    .frame(width: column.width, alignment: .trailing)
            }
        }
        .padding(.horizontal, 5)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    var emptyRow: some View {
        Text("No categories")
            .foregroundStyle(.secondary)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    var newCategoryRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            TextField("Title", text: $newCategoryTitle)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("new-category-title-field")
                .focused($focusedNewCategoryField, equals: .title)
                .onSubmit(saveNewCategory)

            Spacer()

            ForEach(type.valueColumns) { column in
                if column.isEditable {
                    TextField(column.title, text: newCategoryAmountBinding(for: column))
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .accessibilityIdentifier("new-category-\(column.id)-field")
                        .frame(width: column.width)
                        .focused($focusedNewCategoryField, equals: .amount(column.id))
                        .onSubmit(saveNewCategory)
                } else {
                    Text(formattedAmount(0))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(width: column.width, alignment: .trailing)
                }
            }
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 8)
        .onAppear {
            focusedNewCategoryField = .title
        }
        .onExitCommand {
            discardNewCategory()
        }
    }

    var totalRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack {
                Button {
                    startCreatingCategory()
                } label: {
                    Label(type.addButtonTitle, systemImage: "plus")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .help("Add \(type.title) Category")
            }
            .padding(.horizontal, 5)

            Spacer()

            ForEach(type.valueColumns) { column in
                Text(formattedAmount(total(for: column)))
                    .fontWeight(.semibold)
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(5)
                    .frame(width: column.width, alignment: .trailing)
            }
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 10)
    }

    func categoryRow(_ category: BudgetCategory) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            editableTitleCell(for: category)

            ForEach(type.valueColumns) { column in
                valueCell(for: category, column: column)
            }
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 8)
        .onDrag {
            draggedCategoryID = category.coreID
            return NSItemProvider(object: "\(category.coreID)" as NSString)
        }
        .onDrop(
            of: [.text],
            delegate: CategoryDropDelegate(
                targetCategory: category,
                categories: categories,
                draggedCategoryID: $draggedCategoryID,
                dropTargetCategoryID: $dropTargetCategoryID,
                onReorderCategories: onReorderCategories
            )
        )
        .contextMenu {
            Button(role: .destructive) {
                categoryPendingRemoval = category
            } label: {
                Label("Delete Category", systemImage: "trash")
            }
        }
    }

    func dropIndicator(for category: BudgetCategory) -> some View {
        Rectangle()
            .fill(Color.accentColor)
            .frame(height: dropTargetCategoryID == category.coreID ? 2 : 0)
    }

    func editableTitleCell(for category: BudgetCategory) -> some View {
        Group {
            if editingCell == .title(category.coreID) {
                TextField("Title", text: $editedValue)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedEditingCell, equals: .title(category.coreID))
                    .onAppear {
                        focusEditingCell(.title(category.coreID))
                    }
                    .onSubmit {
                        commitTitleEdit(for: category)
                    }
                    .onExitCommand {
                        discardEdit()
                    }
            } else {
                ClickableTableCell {
                    startEditing(.title(category.coreID), value: category.title)
                } label: {
                    Text(category.title)
                        .fontWeight(.medium)
                }
            }
        }
    }

    func valueCell(for category: BudgetCategory, column: CategoryValueColumn) -> some View {
        Group {
            if editingCell == .amount(category.coreID, column.id) {
                TextField(column.title, text: $editedValue)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: column.width)
                    .focused($focusedEditingCell, equals: .amount(category.coreID, column.id))
                    .onAppear {
                        focusEditingCell(.amount(category.coreID, column.id))
                    }
                    .onSubmit {
                        commitAmountEdit(for: category, column: column)
                    }
                    .onExitCommand {
                        discardEdit()
                    }
            } else if column.opensTransaction {
                ClickableTableCell(width: column.width, alignment: .trailing) {
                    onAddTransaction(category)
                } label: {
                    amountText(category.amount(for: column))
                }
            } else if column.isEditable {
                ClickableTableCell(width: column.width, alignment: .trailing) {
                    startEditing(.amount(category.coreID, column.id), value: category.amount(for: column).moneyAmountInputText)
                } label: {
                    amountText(category.amount(for: column))
                }
            } else {
                amountText(category.amount(for: column))
                    .frame(width: column.width, alignment: .trailing)
            }
        }
    }

    func rowSeparator(for category: BudgetCategory) -> some View {
        ZStack {
            GeometryReader { proxy in
                Rectangle()
                    .fill(progressColor(for: category))
                    .frame(width: proxy.size.width * progressFraction(for: category))
            }
            .frame(height: 2)

            Divider()
        }
    }

    func amountText(_ amount: UInt64) -> some View {
        Text(formattedAmount(amount))
            .monospacedDigit()
    }

    func progressFraction(for category: BudgetCategory) -> CGFloat {
        guard category.amountPlanned > 0 else {
            return category.amountActual > 0 ? 1 : 0
        }

        let fraction = CGFloat(category.amountActual) / CGFloat(category.amountPlanned)
        return min(fraction, 1)
    }

    func progressColor(for category: BudgetCategory) -> Color {
        category.amountPlanned > 0 && category.amountActual > category.amountPlanned
            ? Color(nsColor: .systemRed)
            : Color(nsColor: .systemGreen)
    }

    func startCreatingCategory() {
        isCreatingCategory = true
        newCategoryTitle = ""
        newCategoryPlanned = "0"
        newCategoryAccumulated = "0"
        focusedNewCategoryField = .title
    }

    func saveNewCategory() {
        let title = newCategoryTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            !title.isEmpty,
            let planned = parsedAmount(newCategoryPlanned),
            let accumulated = parsedAmount(newCategoryAccumulated)
        else {
            return
        }

        onAddCategory(title, planned, type.allowsAccumulatedAmount ? accumulated : 0)
        isCreatingCategory = false
        newCategoryTitle = ""
        newCategoryPlanned = "0"
        newCategoryAccumulated = "0"
        focusedNewCategoryField = nil
    }

    func discardNewCategory() {
        isCreatingCategory = false
        newCategoryTitle = ""
        newCategoryPlanned = "0"
        newCategoryAccumulated = "0"
        focusedNewCategoryField = nil
    }

    func newCategoryAmountBinding(for column: CategoryValueColumn) -> Binding<Swift.String> {
        Binding {
            column.id == "accumulated" ? newCategoryAccumulated : newCategoryPlanned
        } set: { value in
            if column.id == "accumulated" {
                newCategoryAccumulated = value
            } else {
                newCategoryPlanned = value
            }
        }
    }

    func startEditing(_ cell: EditingCell, value: Swift.String) {
        if editingCell != nil, editingCell != cell {
            isProgrammaticallyChangingEditingCell = true
            commitActiveEdit()
            isProgrammaticallyChangingEditingCell = true
        }

        editingCell = cell
        editedValue = value
        focusEditingCell(cell)
    }

    func focusEditingCell(_ cell: EditingCell) {
        DispatchQueue.main.async {
            focusedEditingCell = cell
            isProgrammaticallyChangingEditingCell = false
        }
    }

    func discardEdit() {
        editingCell = nil
        editedValue = ""
        focusedEditingCell = nil
        isProgrammaticallyChangingEditingCell = false
    }

    func commitActiveEdit() {
        guard let editingCell else {
            return
        }

        switch editingCell {
        case .title(let categoryID):
            guard let category = categories.first(where: { $0.coreID == categoryID }) else {
                discardEdit()
                return
            }

            commitTitleEdit(for: category)
        case .amount(let categoryID, let columnID):
            guard
                let category = categories.first(where: { $0.coreID == categoryID }),
                let column = type.valueColumns.first(where: { $0.id == columnID })
            else {
                discardEdit()
                return
            }

            commitAmountEdit(for: category, column: column)
        }
    }

    func commitTitleEdit(for category: BudgetCategory) {
        let title = editedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            discardEdit()
            return
        }

        onUpdateCategory(
            CategoryUpdate(
                categoryID: category.coreID,
                title: title,
                amountPlanned: category.amountPlanned,
                amountAccumulated: category.amountAccumulated
            )
        )
        editingCell = nil
        editedValue = ""
        focusedEditingCell = nil
    }

    func commitAmountEdit(for category: BudgetCategory, column: CategoryValueColumn) {
        guard let amount = parsedAmount(editedValue) else {
            discardEdit()
            return
        }

        onUpdateCategory(
            CategoryUpdate(
                categoryID: category.coreID,
                title: category.title,
                amountPlanned: column.id == "planned" ? amount : category.amountPlanned,
                amountAccumulated: column.id == "accumulated" ? amount : category.amountAccumulated
            )
        )
        editingCell = nil
        editedValue = ""
        focusedEditingCell = nil
    }

    func total(for column: CategoryValueColumn) -> UInt64 {
        categories.reduce(0) { $0 + $1.amount(for: column) }
    }

    func parsedAmount(_ text: Swift.String) -> UInt64? {
        UInt64.parseMoneyAmount(text)
    }

    func formattedAmount(_ amount: UInt64) -> Swift.String {
        amount.formattedMoneyAmount(currency: currency)
    }
}

private enum EditingCell: Hashable {
    case title(Int)
    case amount(Int, Swift.String)
}

private enum NewCategoryField: Hashable {
    case title
    case amount(Swift.String)
}

private struct CategoryDropDelegate: DropDelegate {
    let targetCategory: BudgetCategory
    let categories: [BudgetCategory]
    @Binding var draggedCategoryID: Int?
    @Binding var dropTargetCategoryID: Int?
    let onReorderCategories: ([Int]) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        draggedCategoryID != nil
    }

    func dropEntered(info: DropInfo) {
        guard draggedCategoryID != targetCategory.coreID else {
            return
        }

        dropTargetCategoryID = targetCategory.coreID
    }

    func dropExited(info: DropInfo) {
        if dropTargetCategoryID == targetCategory.coreID {
            dropTargetCategoryID = nil
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        defer {
            self.draggedCategoryID = nil
            self.dropTargetCategoryID = nil
        }

        guard
            let draggedCategoryID,
            draggedCategoryID != targetCategory.coreID,
            let sourceIndex = categories.firstIndex(where: { $0.coreID == draggedCategoryID }),
            let targetIndex = categories.firstIndex(where: { $0.coreID == targetCategory.coreID })
        else {
            return false
        }

        var reorderedCategories = categories
        let movedCategory = reorderedCategories.remove(at: sourceIndex)
        let insertionIndex = sourceIndex < targetIndex ? targetIndex : targetIndex
        reorderedCategories.insert(movedCategory, at: insertionIndex)

        onReorderCategories(reorderedCategories.map(\.coreID))
        return true
    }
}

private struct ClickableTableCell<Label: View>: View {
    let width: CGFloat?
    let alignment: Alignment
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    @State private var isHovering = false

    init(
        width: CGFloat? = nil,
        alignment: Alignment = .leading,
        _ action: @escaping () -> Void,
        @ViewBuilder label: @escaping () -> Label
    ) {
        self.width = width
        self.alignment = alignment
        self.action = action
        self.label = label
    }

    var body: some View {
        label()
            .frame(maxWidth: .infinity, alignment: alignment)
            .padding(5)
            .contentShape(.rect)
            .onTapGesture(perform: action)
            .frame(width: width, alignment: alignment)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: alignment)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(isHovering ? Color.accentColor.opacity(0.12) : Color.clear)
            )
            .contentShape(.rect)
            .onHover { isHovering = $0 }
    }
}

private struct CategoryValueColumn: Identifiable {
    let id: Swift.String
    let title: Swift.String
    let amount: KeyPath<BudgetCategory, UInt64>
    let width: CGFloat

    var isEditable: Bool {
        id == "planned" || id == "accumulated"
    }

    var opensTransaction: Bool {
        id == "actual"
    }
}

private extension BudgetCategory {
    func amount(for column: CategoryValueColumn) -> UInt64 {
        self[keyPath: column.amount]
    }
}

private extension BudgetCategoryType {
    var allowsAccumulatedAmount: Bool {
        self == .savings || self == .debt
    }

    var valueColumns: [CategoryValueColumn] {
        switch self {
        case .income:
            return [
                CategoryValueColumn(id: "planned", title: "Planned", amount: \.amountPlanned, width: 92),
                CategoryValueColumn(id: "actual", title: "Received", amount: \.amountActual, width: 92)
            ]
        case .expenses:
            return [
                CategoryValueColumn(id: "planned", title: "Planned", amount: \.amountPlanned, width: 92),
                CategoryValueColumn(id: "actual", title: "Spend", amount: \.amountActual, width: 92)
            ]
        case .debt:
            return [
                CategoryValueColumn(id: "accumulated", title: "Leftover Debt", amount: \.amountAccumulated, width: 118),
                CategoryValueColumn(id: "planned", title: "Planned", amount: \.amountPlanned, width: 92),
                CategoryValueColumn(id: "actual", title: "Paid", amount: \.amountActual, width: 92)
            ]
        case .savings:
            return [
                CategoryValueColumn(id: "accumulated", title: "Accumulated", amount: \.amountAccumulated, width: 118),
                CategoryValueColumn(id: "planned", title: "Planned", amount: \.amountPlanned, width: 92),
                CategoryValueColumn(id: "actual", title: "Saved", amount: \.amountActual, width: 92)
            ]
        }
    }

    var addButtonTitle: Swift.String {
        switch self {
        case .income:
            return "New Income"
        case .expenses:
            return "New Category"
        case .debt:
            return "New Loan"
        case .savings:
            return "New Fund"
        }
    }
}
