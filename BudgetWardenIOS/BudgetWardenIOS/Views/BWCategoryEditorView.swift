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
    let saveCategory: (BWCategoryDraft) async -> Bool

    @Environment(\.dismiss) private var dismiss

    @State private var title: String
    @State private var plannedAmount: String
    @State private var categoryType: BWCategoryType

    init(
        editor: BWCategoryEditor,
        saveCategory: @escaping (BWCategoryDraft) async -> Bool
    ) {
        self.editor = editor
        self.saveCategory = saveCategory
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
        NavigationStack {
            Form {
                Section("Category") {
                    TextField("Title", text: $title)

                    Picker("Type", selection: $categoryType) {
                        ForEach(BWCategoryType.allCases, id: \.self) { categoryType in
                            Text(categoryType.title)
                                .tag(categoryType)
                        }
                    }

                    TextField("Planned Amount", text: $plannedAmount)
                        .keyboardType(.decimalPad)
                }
            }
            .navigationTitle(editor.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) {
                        dismiss()
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
                    .disabled(!canSave)
                }
            }
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
