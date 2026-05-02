import AppKit
import SwiftUI

struct CategoryListView: View {
    let type: BudgetCategoryType
    let categories: [BudgetCategory]
    let onAddCategory: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(spacing: 15) {
                Text(type.title)
                    .font(.headline)

                Button {
                    onAddCategory()
                } label: {
                    Image(systemName: "plus")
                }
                .help("Add \(type.title) Category")
            }

            VStack(alignment: .leading, spacing: 0) {
                if categories.isEmpty {
                    Text("No categories")
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ForEach(categories) { category in
                        CategoryRowView(category: category)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        if category.id != categories.last?.id {
                            Divider()
                        }
                    }
                }
            }
            .background(rowBackground)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    private var rowBackground: Color {
        Color(nsColor: .controlBackgroundColor)
    }
}
