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

struct BWCategoryEditorView: View {
    let editor: BWCategoryEditor
    let currency: BWCurrency
    let saveCategory: (BWCategoryDraft) async -> Bool
    let deleteCategory: (() async -> Void)?
    let embedsInNavigationStack: Bool
    let showsCancelButton: Bool

    @Environment(\.dismiss) private var dismiss

    @State private var title: String
    @State private var plannedAmount: String
    @State private var categoryType: BWCategoryType
    @State private var deleteConfirmationIsPresented = false

    init(
        editor: BWCategoryEditor,
        currency: BWCurrency,
        saveCategory: @escaping (BWCategoryDraft) async -> Bool,
        deleteCategory: (() async -> Void)? = nil,
        embedsInNavigationStack: Bool = true,
        showsCancelButton: Bool = true
    ) {
        self.editor = editor
        self.currency = currency
        self.saveCategory = saveCategory
        self.deleteCategory = deleteCategory
        self.embedsInNavigationStack = embedsInNavigationStack
        self.showsCancelButton = showsCancelButton
        _title = State(initialValue: editor.initialTitle)
        _plannedAmount = State(initialValue: editor.initialPlannedAmount.moneyInputText)
        _categoryType = State(initialValue: editor.initialCategoryType)
    }

    private var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var parsedPlannedAmount: UInt64? {
        UInt64.parseMoneyAmount(plannedAmount, emptyValue: 0)
    }

    private var canSave: Bool {
        !trimmedTitle.isEmpty && parsedPlannedAmount != nil
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
            Section("Category") {
                LabeledContent("Title") {
                    TextField("Title", text: $title)
                        .multilineTextAlignment(.trailing)
                        .accessibilityIdentifier("categoryTitleTextField")
                }

                Picker("Type", selection: $categoryType) {
                    ForEach(BWCategoryType.allCases, id: \.self) { categoryType in
                        Text(categoryType.title)
                            .tag(categoryType)
                    }
                }
                .accessibilityIdentifier("categoryTypePicker")
            }

            Section("Amounts") {
                LabeledContent("Planned") {
                    TextField("0.00", text: $plannedAmount)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .accessibilityIdentifier("categoryPlannedTextField")
                }

                if let actualAmount {
                    LabeledContent("Actual") {
                        Text(actualAmount.formattedMoneyAmount(currency: currency))
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("categoryActualValue")
                    }
                }
            }

            if deleteCategory != nil {
                Section {
                    Button("Delete Category", systemImage: "trash", role: .destructive) {
                        deleteConfirmationIsPresented = true
                    }
                    .accessibilityIdentifier("categoryEditorDeleteButton")
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
                    .accessibilityIdentifier("categoryCancelButton")
                }
            }

            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    Task {
                        guard let parsedPlannedAmount else {
                            return
                        }

                        let draft = BWCategoryDraft(
                            mode: draftMode,
                            title: trimmedTitle,
                            plannedAmount: parsedPlannedAmount,
                            categoryType: categoryType
                        )

                        if await saveCategory(draft) {
                            dismiss()
                        }
                    }
                }
                .accessibilityIdentifier("categorySaveButton")
                .disabled(!canSave)
            }
        }
        .alert(
            "Delete Category?",
            isPresented: $deleteConfirmationIsPresented,
            actions: {
                Button("Delete Category", role: .destructive) {
                    Task {
                        await deleteCategory?()
                        dismiss()
                    }
                }
                .accessibilityIdentifier("categoryEditorDeleteConfirmButton")

                Button("Cancel", role: .cancel) {}
            },
            message: {
                Text("This will also delete the category's transactions.")
            }
        )
    }

    private var actualAmount: UInt64? {
        switch editor {
            case .create:
                return nil
            case .edit(let category):
                return category.amountActual
        }
    }

    private var draftMode: BWCategoryDraftMode {
        switch editor {
            case .create:
                return .create
            case .edit(let category):
                return .edit(category)
        }
    }
}
