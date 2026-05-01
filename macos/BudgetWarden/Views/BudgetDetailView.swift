import AppKit
import SwiftUI

struct BudgetDetailView: View {
    let budget: BudgetDocument
    let onAddCategory: (Swift.String, BudgetCategoryType) -> Void

    @State private var categoryTypeToCreate: BudgetCategoryType?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(budget.title)
                    .font(.title2)
                    .fontWeight(.semibold)

                Text(budget.period)
                    .foregroundStyle(.secondary)
            }

            ForEach(BudgetCategoryType.allCases) { type in
                categoryList(for: type)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle(budget.title)
        .sheet(item: $categoryTypeToCreate) { type in
            CreateCategoryView(
                type: type,
                onSave: { title in
                    onAddCategory(title, type)
                    categoryTypeToCreate = nil
                },
                onCancel: {
                    categoryTypeToCreate = nil
                }
            )
            .frame(minWidth: 360)
        }
    }

    private func categoryList(for type: BudgetCategoryType) -> some View {
        CategoryListView(
            type: type,
            categories: budget.categories(for: type)
        ) {
            categoryTypeToCreate = type
        }
    }
}
