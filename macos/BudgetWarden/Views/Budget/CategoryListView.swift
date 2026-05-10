/* 
 * Budget Warden
 * Copyright (c) 2026 Lazarov & Co EOOD
 * Author: Nikola Lazarov
 *
 * Licensed under the Source-Available Educational License. 
 * See the LICENSE file in the project root for full terms.
 *
 */

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct CategoryListView: View {
    @ObservedObject var store: BWStore
    let budgetURL: URL
    let type: BudgetCategoryType
    let onAddTransaction: (Int) -> Void

    @State private var isCreatingCategory = false
    @State private var newCategoryTitle = ""
    @State private var newCategoryPlanned = "0"
    @State private var newCategoryAccumulated = "0"
    @State private var editingCell: EditingCell?
    @State private var editedValue = ""
    @State private var categoryPendingRemoval: Int?
    @State private var draggedCategoryID: Int?
    @State private var dropTargetCategoryID: Int?
    @State private var isProgrammaticallyChangingEditingCell = false
    @State private var tableWidth: CGFloat = 0
    @FocusState private var focusedNewCategoryField: NewCategoryField?
    @FocusState private var focusedEditingCell: EditingCell?

    private var categoryIDs: [Int] {
        store.categoryIDs(for: type, in: budgetURL)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerRow

            VStack(alignment: .leading, spacing: 0) {
                if categoryIDs.isEmpty && !isCreatingCategory {
                    emptyRow
                    Divider()
                } else {
                    ForEach(categoryIDs, id: \.self) { categoryID in
                        dropIndicator(for: categoryID)
                        categoryRow(categoryID)
                        rowSeparator(for: categoryID)
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
        .overlay {
            GeometryReader { proxy in
                Color.clear
                    .onAppear {
                        tableWidth = proxy.size.width
                    }
                    .onChange(of: proxy.size.width) { _, width in
                        tableWidth = width
                    }
            }
        }
        .clipShape(.rect(cornerRadius: 8, style: .continuous))
        .confirmationDialog(
            "Delete Category?",
            isPresented: removeCategoryConfirmationBinding,
            presenting: categoryPendingRemoval
        ) { category in
            Button("Delete Category", role: .destructive) {
                store.removeCategory(categoryID: category)
                categoryPendingRemoval = nil
            }

            Button("Cancel", role: .cancel) {
                categoryPendingRemoval = nil
            }
        } message: { categoryID in
            Text("Delete \(categoryTitle(categoryID))? This will also remove its transactions.")
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
                    .frame(width: valueColumnWidth(for: column), alignment: .trailing)
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
                        .frame(width: valueColumnWidth(for: column))
                        .focused($focusedNewCategoryField, equals: .amount(column.id))
                        .onSubmit(saveNewCategory)
                } else {
                    Text(formattedAmount(0))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(width: valueColumnWidth(for: column), alignment: .trailing)
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
                .accessibilityIdentifier("category-add-\(type.accessibilityID)-button")
            }
            .padding(.horizontal, 5)

            Spacer()

            ForEach(type.valueColumns) { column in
                Text(formattedAmount(total(for: column)))
                    .fontWeight(.semibold)
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(5)
                    .frame(width: valueColumnWidth(for: column), alignment: .trailing)
            }
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 10)
    }

    func categoryRow(_ categoryID: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            editableTitleCell(for: categoryID)

            ForEach(type.valueColumns) { column in
                valueCell(for: categoryID, column: column)
            }
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 8)
        .onDrag {
            draggedCategoryID = categoryID
            return NSItemProvider(object: "\(categoryID)" as NSString)
        }
        .onDrop(
            of: [.text],
            delegate: CategoryDropDelegate(
                targetCategoryID: categoryID,
                categoryIDs: categoryIDs,
                draggedCategoryID: $draggedCategoryID,
                dropTargetCategoryID: $dropTargetCategoryID,
                onReorderCategories: { orderedCategoryIDs in
                    store.reorderCategories(type: type, orderedCategoryIDs: orderedCategoryIDs)
                }
            )
        )
        .contextMenu {
            Button(role: .destructive) {
                categoryPendingRemoval = categoryID
            } label: {
                Label("Delete Category", systemImage: "trash")
            }
        }
    }

    func dropIndicator(for categoryID: Int) -> some View {
        Rectangle()
            .fill(Color.accentColor)
            .frame(height: dropTargetCategoryID == categoryID ? 2 : 0)
    }

    func editableTitleCell(for categoryID: Int) -> some View {
        let title = categoryTitle(categoryID)

        return Group {
            if editingCell == .title(categoryID) {
                TextField("Title", text: $editedValue)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("category-title-edit-field")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .focused($focusedEditingCell, equals: .title(categoryID))
                    .background {
                        OutsideClickCommitObserver {
                            commitTitleEdit(for: categoryID)
                        }
                    }
                    .onAppear {
                        focusEditingCell(.title(categoryID))
                    }
                    .onSubmit {
                        commitTitleEdit(for: categoryID)
                    }
                    .onExitCommand {
                        discardEdit()
                    }
            } else {
                ClickableTableCell {
                    startEditing(.title(categoryID), value: title)
                } label: {
                    Text(title)
                        .fontWeight(.medium)
                }
                .accessibilityIdentifier("category-title-cell-\(title.accessibilityIdentifierComponent)")
                .contextMenu {
                    Button(role: .destructive) {
                        categoryPendingRemoval = categoryID
                    } label: {
                        Label("Delete Category", systemImage: "trash")
                    }
                }
            }
        }
    }

    func valueCell(for categoryID: Int, column: CategoryValueColumn) -> some View {
        let category = store.category(categoryID, in: budgetURL)
        let amount = category?.amount(column.amount) ?? 0
        let accessibilityID = (category?.title.swiftString() ?? "").accessibilityIdentifierComponent

        return Group {
            if editingCell == .amount(categoryID, column.id) {
                TextField(column.title, text: $editedValue)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .accessibilityIdentifier("category-\(column.id)-edit-field")
                    .frame(width: valueColumnWidth(for: column))
                    .focused($focusedEditingCell, equals: .amount(categoryID, column.id))
                    .background {
                        OutsideClickCommitObserver {
                            commitAmountEdit(for: categoryID, column: column)
                        }
                    }
                    .onAppear {
                        focusEditingCell(.amount(categoryID, column.id))
                    }
                    .onSubmit {
                        commitAmountEdit(for: categoryID, column: column)
                    }
                    .onExitCommand {
                        discardEdit()
                    }
            } else if column.opensTransaction {
                Button {
                    onAddTransaction(categoryID)
                } label: {
                    amountText(amount)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(5)
                        .frame(width: valueColumnWidth(for: column), alignment: .trailing)
                }
                .buttonStyle(.plain)
                .contentShape(.rect)
                .accessibilityIdentifier("category-\(column.id)-cell-\(accessibilityID)")
            } else if column.isEditable {
                ClickableTableCell(width: valueColumnWidth(for: column), alignment: .trailing) {
                    startEditing(.amount(categoryID, column.id), value: amount.moneyAmountInputText)
                } label: {
                    amountText(amount)
                        .accessibilityIdentifier("category-\(column.id)-cell-\(accessibilityID)")
                }
            } else {
                amountText(amount)
                    .frame(width: valueColumnWidth(for: column), alignment: .trailing)
                    .accessibilityIdentifier("category-\(column.id)-cell-\(accessibilityID)")
            }
        }
    }

    func rowSeparator(for categoryID: Int) -> some View {
        ZStack {
            GeometryReader { proxy in
                Rectangle()
                    .fill(progressColor(for: categoryID))
                    .frame(width: proxy.size.width * progressFraction(for: categoryID))
            }
            .frame(height: 2)

            Divider()
        }
    }

    func amountText(_ amount: UInt64) -> some View {
        Text(formattedAmount(amount))
            .monospacedDigit()
    }

    func progressFraction(for categoryID: Int) -> CGFloat {
        let category = store.category(categoryID, in: budgetURL)
        let planned = category?.amount_planned ?? 0
        let actual = category?.amount_actual ?? 0

        guard planned > 0 else {
            return actual > 0 ? 1 : 0
        }

        let fraction = CGFloat(actual) / CGFloat(planned)
        return min(fraction, 1)
    }

    func progressColor(for categoryID: Int) -> Color {
        let category = store.category(categoryID, in: budgetURL)
        let planned = category?.amount_planned ?? 0
        let actual = category?.amount_actual ?? 0

        return planned > 0 && actual > planned
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

        store.addCategory(
            title: title,
            amountPlanned: planned,
            amountAccumulated: type.allowsAccumulatedAmount ? accumulated : 0,
            type: type
        )
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
            guard categoryIDs.contains(categoryID) else {
                discardEdit()
                return
            }

            commitTitleEdit(for: categoryID)
        case .amount(let categoryID, let columnID):
            guard
                categoryIDs.contains(categoryID),
                let column = type.valueColumns.first(where: { $0.id == columnID })
            else {
                discardEdit()
                return
            }

            commitAmountEdit(for: categoryID, column: column)
        }
    }

    func commitTitleEdit(for categoryID: Int) {
        let title = editedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            discardEdit()
            return
        }

        store.updateCategory(
            CategoryUpdate(
                categoryID: categoryID,
                title: title,
                amountPlanned: categoryAmount(categoryID, field: .planned),
                amountAccumulated: categoryAmount(categoryID, field: .accumulated)
            )
        )
        editingCell = nil
        editedValue = ""
        focusedEditingCell = nil
    }

    func commitAmountEdit(for categoryID: Int, column: CategoryValueColumn) {
        guard let amount = parsedAmount(editedValue) else {
            discardEdit()
            return
        }

        store.updateCategory(
            CategoryUpdate(
                categoryID: categoryID,
                title: categoryTitle(categoryID),
                amountPlanned: column.id == "planned" ? amount : categoryAmount(categoryID, field: .planned),
                amountAccumulated: column.id == "accumulated" ? amount : categoryAmount(categoryID, field: .accumulated)
            )
        )
        editingCell = nil
        editedValue = ""
        focusedEditingCell = nil
    }

    func total(for column: CategoryValueColumn) -> UInt64 {
        store.categoryTotal(type: type, field: column.amount, in: budgetURL)
    }

    func categoryAmount(_ categoryID: Int, column: CategoryValueColumn) -> UInt64 {
        categoryAmount(categoryID, field: column.amount)
    }

    func categoryAmount(_ categoryID: Int, field: CategoryAmountField) -> UInt64 {
        store.category(categoryID, in: budgetURL)?.amount(field) ?? 0
    }

    func categoryTitle(_ categoryID: Int) -> Swift.String {
        store.category(categoryID, in: budgetURL)?.title.swiftString() ?? ""
    }

    func parsedAmount(_ text: Swift.String) -> UInt64? {
        UInt64.parseMoneyAmount(text)
    }

    func formattedAmount(_ amount: UInt64) -> Swift.String {
        amount.formattedMoneyAmount(currency: store.selectedCurrency)
    }

    func valueColumnWidth(for column: CategoryValueColumn) -> CGFloat {
        let contentWidth = valueColumnContentWidth(for: column)
        let availableWidth = tableWidth > 0 ? tableWidth : 700
        let maximumWidth = max(96, floor(availableWidth * 0.16))

        return min(max(contentWidth, 76), maximumWidth)
    }

    func valueColumnContentWidth(for column: CategoryValueColumn) -> CGFloat {
        var values = categoryIDs.map { formattedAmount(categoryAmount($0, column: column)) }
        values.append(formattedAmount(total(for: column)))

        if isCreatingCategory {
            if column.id == "planned" {
                values.append(newCategoryPlanned)
            } else if column.id == "accumulated" {
                values.append(newCategoryAccumulated)
            } else {
                values.append(formattedAmount(0))
            }
        }

        if case .amount(_, let columnID) = editingCell, columnID == column.id {
            values.append(editedValue)
        }

        let widestValue = values
            .map { measuredMoneyTextWidth($0) }
            .max() ?? 0
        let headerWidth = measuredHeaderTextWidth(column.title)

        return ceil(max(widestValue, headerWidth) + 18)
    }

    func measuredMoneyTextWidth(_ text: Swift.String) -> CGFloat {
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        let attributes: [NSAttributedString.Key: Any] = [.font: font]

        return (text as NSString).size(withAttributes: attributes).width
    }

    func measuredHeaderTextWidth(_ text: Swift.String) -> CGFloat {
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        let attributes: [NSAttributedString.Key: Any] = [.font: font]

        return (text as NSString).size(withAttributes: attributes).width
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

struct OutsideClickCommitObserver: NSViewRepresentable {
    let onOutsideClick: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.view = view
        context.coordinator.onOutsideClick = onOutsideClick
        context.coordinator.installMonitor()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.view = nsView
        context.coordinator.onOutsideClick = onOutsideClick
        context.coordinator.installMonitor()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        weak var view: NSView?
        var onOutsideClick: (() -> Void)?
        private var monitor: Any?

        deinit {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
        }

        func installMonitor() {
            guard monitor == nil else {
                return
            }

            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                self?.handle(event)
                return event
            }
        }

        private func handle(_ event: NSEvent) {
            guard
                let view,
                let window = view.window,
                event.window === window
            else {
                return
            }

            let frameInWindow = view.convert(view.bounds, to: nil)
            if !frameInWindow.contains(event.locationInWindow) {
                onOutsideClick?()
            }
        }
    }
}

private struct CategoryDropDelegate: DropDelegate {
    let targetCategoryID: Int
    let categoryIDs: [Int]
    @Binding var draggedCategoryID: Int?
    @Binding var dropTargetCategoryID: Int?
    let onReorderCategories: ([Int]) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        draggedCategoryID != nil
    }

    func dropEntered(info: DropInfo) {
        guard draggedCategoryID != targetCategoryID else {
            return
        }

        dropTargetCategoryID = targetCategoryID
    }

    func dropExited(info: DropInfo) {
        if dropTargetCategoryID == targetCategoryID {
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
            draggedCategoryID != targetCategoryID,
            let sourceIndex = categoryIDs.firstIndex(of: draggedCategoryID),
            let targetIndex = categoryIDs.firstIndex(of: targetCategoryID)
        else {
            return false
        }

        var reorderedCategories = categoryIDs
        let movedCategoryID = reorderedCategories.remove(at: sourceIndex)
        let insertionIndex = sourceIndex < targetIndex ? targetIndex : targetIndex
        reorderedCategories.insert(movedCategoryID, at: insertionIndex)

        onReorderCategories(reorderedCategories)
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
    let amount: CategoryAmountField

    var isEditable: Bool {
        id == "planned" || id == "accumulated"
    }

    var opensTransaction: Bool {
        id == "actual"
    }
}

private extension BudgetCategoryType {
    var accessibilityID: Swift.String {
        switch self {
        case .income:
            return "income"
        case .expenses:
            return "expenses"
        case .debt:
            return "debt"
        case .savings:
            return "savings"
        }
    }

    var allowsAccumulatedAmount: Bool {
        self == .savings || self == .debt
    }

    var valueColumns: [CategoryValueColumn] {
        switch self {
        case .income:
            return [
                CategoryValueColumn(id: "planned", title: "Planned", amount: .planned),
                CategoryValueColumn(id: "actual", title: "Received", amount: .actual)
            ]
        case .expenses:
            return [
                CategoryValueColumn(id: "planned", title: "Planned", amount: .planned),
                CategoryValueColumn(id: "actual", title: "Spend", amount: .actual)
            ]
        case .debt:
            return [
                CategoryValueColumn(id: "accumulated", title: "Leftover Debt", amount: .accumulated),
                CategoryValueColumn(id: "planned", title: "Planned", amount: .planned),
                CategoryValueColumn(id: "actual", title: "Paid", amount: .actual)
            ]
        case .savings:
            return [
                CategoryValueColumn(id: "accumulated", title: "Accumulated", amount: .accumulated),
                CategoryValueColumn(id: "planned", title: "Planned", amount: .planned),
                CategoryValueColumn(id: "actual", title: "Saved", amount: .actual)
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

private extension Swift.String {
    var accessibilityIdentifierComponent: Swift.String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalars = unicodeScalars.map { scalar in
            allowed.contains(scalar) ? Character(scalar) : "-"
        }

        return Swift.String(scalars)
    }
}
