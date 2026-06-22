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

struct BWDetailView: View {
    let store: BWAppStore
    let budget: BWBudget
    let currency: BWCurrency
    @Binding var editor: BWCategoryEditor?

    @State private var selectedAmount: BWCategoryAmount = .planned
    @State private var categoryPendingEdit: BWCategory?
    @State private var categoriesPendingDeletion: [BWCategory] = []

    var body: some View {
        List {
            Picker("Amount", selection: $selectedAmount) {
                ForEach(BWCategoryAmount.allCases) { amount in
                    Text(amount.title).tag(amount)
                }
            }
            .accessibilityIdentifier("categoryAmountPicker")
            .pickerStyle(.segmented)
            .environment(\.defaultMinListRowHeight, 0)
            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
            .listRowSeparator(.hidden)
            .listRowBackground(Color(.systemGroupedBackground))

            ForEach(BWCategoryType.allCases, id: \.self) { categoryType in
                Section(categoryType.title) {
                    ForEach(categories(for: categoryType)) { category in
                        NavigationLink {
                            categoryEditor(for: category)
                        } label: {
                            BWCategoryRow(
                                category: category,
                                selectedAmount: selectedAmount,
                                currency: currency
                            )
                        }
                        .accessibilityIdentifier("categoryRow_\(category.title)")
                        .swipeActions(edge: .trailing) {
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                Task {
                                    await store.deleteCategory(category, in: budget.id)
                                }
                            }

                            Button("Edit", systemImage: "pencil") {
                                categoryPendingEdit = category
                            }
                            .tint(.blue)
                        }
                        .contextMenu {
                            Button("Edit", systemImage: "pencil") {
                                categoryPendingEdit = category
                            }

                            Button("Delete", systemImage: "trash", role: .destructive) {
                                confirmDeletion(of: [category])
                            }
                        }
                    }
                    .onDelete { offsets in
                        deleteCategories(at: offsets, in: categoryType)
                    }

                    Button {
                        editor = .create(categoryType)
                    } label: {
                        Label(createLabel(for: categoryType), systemImage: "plus")
                    }
                    .accessibilityIdentifier("create\(categoryType.title)CategoryButton")
                }
            }
        }
        .contentMargins(.top, 0, for: .scrollContent)
        .alert(
            deleteConfirmationTitle,
            isPresented: Binding(
                get: { !categoriesPendingDeletion.isEmpty },
                set: { isPresented in
                    if !isPresented {
                        categoriesPendingDeletion = []
                    }
                }
            ),
            actions: {
                Button(deleteConfirmationActionTitle, role: .destructive) {
                    deletePendingCategories()
                }
                .accessibilityIdentifier("categoryDeleteConfirmButton")

                Button("Cancel", role: .cancel) {
                    categoriesPendingDeletion = []
                }
            },
            message: {
                Text("This will also delete the category's transactions.")
            }
        )
        .navigationDestination(
            isPresented: Binding(
                get: { categoryPendingEdit != nil },
                set: { isPresented in
                    if !isPresented {
                        categoryPendingEdit = nil
                    }
                }
            )
        ) {
            if let categoryPendingEdit {
                categoryEditor(for: categoryPendingEdit)
            }
        }
        .sheet(item: $editor) { editor in
            BWCategoryEditorView(
                editor: editor,
                currency: currency,
                saveCategory: saveCategory
            )
        }
    }

    private func categories(for categoryType: BWCategoryType) -> [BWCategory] {
        BWBudgetMutation.orderedCategories(in: budget, for: categoryType)
    }

    private func createLabel(for categoryType: BWCategoryType) -> String {
        switch categoryType {
            case .income:
                return "New Income"
            case .expenses:
                return "New Category"
            case .savings:
                return "New Fund"
            case .debt:
                return "New Debt"
        }
    }

    private func deleteCategories(at offsets: IndexSet, in categoryType: BWCategoryType) {
        let sectionCategories = categories(for: categoryType)
        let categoriesToDelete = offsets.compactMap { index in
            sectionCategories.indices.contains(index) ? sectionCategories[index] : nil
        }

        confirmDeletion(of: categoriesToDelete)
    }

    private func confirmDeletion(of categories: [BWCategory]) {
        categoriesPendingDeletion = categories
    }

    private func deletePendingCategories() {
        let categoriesToDelete = categoriesPendingDeletion
        categoriesPendingDeletion = []

        Task {
            for category in categoriesToDelete {
                await store.deleteCategory(category, in: budget.id)
            }
        }
    }

    private func categoryEditor(for category: BWCategory) -> some View {
        BWCategoryEditorView(
            editor: .edit(category),
            currency: currency,
            saveCategory: saveCategory,
            deleteCategory: {
                await store.deleteCategory(category, in: budget.id)
            },
            embedsInNavigationStack: false,
            showsCancelButton: false
        )
    }

    private var deleteConfirmationTitle: String {
        categoriesPendingDeletion.count == 1 ? "Delete Category?" : "Delete Categories?"
    }

    private var deleteConfirmationActionTitle: String {
        categoriesPendingDeletion.count == 1 ? "Delete Category" : "Delete Categories"
    }

    private func saveCategory(_ draft: BWCategoryDraft) async -> Bool {
        switch draft.mode {
            case .create:
                return await store.createCategory(
                    in: budget.id,
                    title: draft.title,
                    plannedAmount: draft.plannedAmount,
                    categoryType: draft.categoryType
                )
            case .edit(let originalCategory):
                var category = originalCategory
                category.title = draft.title
                category.amountPlanned = draft.plannedAmount
                category.categoryType = draft.categoryType

                return await store.updateCategory(category, in: budget.id)
        }
    }
}

enum BWCategoryAmount: String, CaseIterable, Identifiable {
    case planned
    case actual

    var id: Self {
        self
    }

    var title: String {
        switch self {
            case .planned:
                return "Planned"
            case .actual:
                return "Actual"
        }
    }

    func amount(for category: BWCategory) -> UInt64 {
        switch self {
            case .planned:
                return category.amountPlanned
            case .actual:
                return category.amountActual
        }
    }
}

enum BWCategoryEditor: Identifiable {
    case create(BWCategoryType)
    case edit(BWCategory)

    var id: String {
        switch self {
            case .create(let categoryType):
                return "create-\(categoryType.rawValue)"
            case .edit(let category):
                return "edit-\(category.id.uuidString)"
        }
    }

    var title: String {
        switch self {
            case .create(let categoryType):
                return "New \(categoryType.title) Category"
            case .edit:
                return "Edit Category"
        }
    }

    var initialCategoryType: BWCategoryType {
        switch self {
            case .create(let categoryType):
                return categoryType
            case .edit(let category):
                return category.categoryType
        }
    }

    var initialTitle: String {
        switch self {
            case .create:
                return ""
            case .edit(let category):
                return category.title
        }
    }

    var initialPlannedAmount: UInt64 {
        switch self {
            case .create:
                return 0
            case .edit(let category):
                return category.amountPlanned
        }
    }
}

enum BWCategoryDraftMode {
    case create
    case edit(BWCategory)
}

struct BWCategoryDraft {
    var mode: BWCategoryDraftMode
    var title: String
    var plannedAmount: UInt64
    var categoryType: BWCategoryType
}
