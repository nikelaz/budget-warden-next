import AppKit
import SwiftUI

struct CategoryListView: View {
    let type: BudgetCategoryType
    let categories: [BudgetCategory]
    let onAddCategory: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(type.title)
                    .font(.headline)

                Spacer()

                Button {
                    onAddCategory()
                } label: {
                    Image(systemName: "plus")
                }
                .help("Add \(type.title) Category")
            }

            List {
                if categories.isEmpty {
                    Text("No categories")
                        .foregroundStyle(.secondary)
                        .listRowBackground(rowBackground)
                } else {
                    ForEach(categories) { category in
                        CategoryRowView(category: category)
                            .listRowBackground(rowBackground)
                    }
                }
            }
            .listStyle(.inset)
        }
        .frame(minHeight: 160)
    }

    private var rowBackground: Color {
        Color(nsColor: .controlBackgroundColor)
    }
}
