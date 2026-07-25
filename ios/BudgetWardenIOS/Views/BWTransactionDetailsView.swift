/*
 * Budget Warden
 * Copyright (c) 2026 Lazarov & Co EOOD
 * Author: Nikola Lazarov
 *
 * Licensed under the Source-Available Educational License.
 * See the LICENSE file in the project root for full terms.
 *
 */

import BWAppleCore
import SwiftUI

struct BWTransactionDetailsView: View {
    let editor: BWTransactionEditor
    let categories: [BWCategory]
    let currency: BWCurrency
    let saveTransaction: (BWTransactionDraft) async -> Bool
    let deleteTransaction: (() async -> Void)?
    let embedsInNavigationStack: Bool
    let showsCancelButton: Bool

    @Environment(\.dismiss) private var dismiss

    @State private var selectedCategoryID: UUID?
    @State private var title: String
    @State private var amount: String
    @State private var date: Date
    @State private var description: String
    @State private var deleteConfirmationIsPresented = false

    init(
        editor: BWTransactionEditor,
        categories: [BWCategory],
        currency: BWCurrency,
        saveTransaction: @escaping (BWTransactionDraft) async -> Bool,
        deleteTransaction: (() async -> Void)? = nil,
        embedsInNavigationStack: Bool = true,
        showsCancelButton: Bool = true
    ) {
        self.editor = editor
        self.categories = categories
        self.currency = currency
        self.saveTransaction = saveTransaction
        self.deleteTransaction = deleteTransaction
        self.embedsInNavigationStack = embedsInNavigationStack
        self.showsCancelButton = showsCancelButton

        switch editor {
            case .create(let initialCategoryID):
                _selectedCategoryID = State(initialValue: initialCategoryID ?? categories.first?.id)
                _title = State(initialValue: "")
                _amount = State(initialValue: "")
                _date = State(initialValue: Date())
                _description = State(initialValue: "")
            case .edit(let item):
                _selectedCategoryID = State(initialValue: item.category.id)
                _title = State(initialValue: item.transaction.title)
                _amount = State(initialValue: item.transaction.amount.moneyInputText)
                _date = State(initialValue: item.transaction.date.foundationDate)
                _description = State(initialValue: item.transaction.description)
        }
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

    private var canSave: Bool {
        guard selectedCategoryID != nil,
              !trimmedTitle.isEmpty,
              let parsedAmount
        else {
            return false
        }

        return parsedAmount > 0
    }

    var body: some View {
        if embedsInNavigationStack {
            NavigationStack {
                content
            }
        }
        else {
            content
        }
    }

    private var content: some View {
        Form {
            Section {
                Picker("Category", selection: $selectedCategoryID) {
                    ForEach(BWCategoryType.allCases, id: \.self) { type in
                        let typeCategories = categories.filter { $0.categoryType == type }

                        if !typeCategories.isEmpty {
                            Text(type.title)
                                .selectionDisabled(true)

                            ForEach(typeCategories) { category in
                                Text(category.title)
                                    .tag(Optional(category.id))
                            }
                        }
                    }
                }
                .accessibilityIdentifier("transactionCategoryPicker")

                LabeledContent("Title") {
                    TextField("Title", text: $title)
                        .multilineTextAlignment(.trailing)
                        .accessibilityIdentifier("transactionTitleTextField")
                }

                LabeledContent("Amount") {
                    TextField("0.00", text: $amount)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .accessibilityIdentifier("transactionAmountTextField")
                }

                DatePicker(
                    "Date",
                    selection: $date,
                    displayedComponents: .date
                )
                .accessibilityIdentifier("transactionDatePicker")

                TextField("Description", text: $description, axis: .vertical)
                    .lineLimit(2...5)
                    .accessibilityIdentifier("transactionDescriptionTextField")
            }

            if deleteTransaction != nil {
                Section {
                    Button("Delete Transaction", systemImage: "trash", role: .destructive) {
                        deleteConfirmationIsPresented = true
                    }
                    .accessibilityIdentifier("transactionEditorDeleteButton")
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .center)
                }
            }
        }
        .navigationTitle(editor.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if showsCancelButton {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) {
                        dismiss()
                    }
                    .accessibilityIdentifier("transactionCancelButton")
                }
            }

            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    Task {
                        guard
                            let selectedCategoryID,
                            let parsedAmount
                        else {
                            return
                        }

                        let draft = BWTransactionDraft(
                            mode: draftMode,
                            categoryID: selectedCategoryID,
                            title: trimmedTitle,
                            description: trimmedDescription,
                            date: date,
                            amount: parsedAmount
                        )

                        if await saveTransaction(draft) {
                            dismiss()
                        }
                    }
                }
                .accessibilityIdentifier("transactionSaveButton")
                .disabled(!canSave)
            }
        }
        .alert(
            "Delete Transaction?",
            isPresented: $deleteConfirmationIsPresented,
            actions: {
                Button("Delete Transaction", role: .destructive) {
                    Task {
                        await deleteTransaction?()
                        dismiss()
                    }
                }
                .accessibilityIdentifier("transactionEditorDeleteConfirmButton")

                Button("Cancel", role: .cancel) {}
            },
            message: {
                Text("This action cannot be undone.")
            }
        )
    }

    private var draftMode: BWTransactionDraftMode {
        switch editor {
            case .create:
                return .create
            case .edit(let item):
                return .edit(item)
        }
    }
}
