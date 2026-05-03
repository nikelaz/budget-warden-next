import SwiftUI

struct CategorySectionView: View {
    let type: BudgetCategoryType
    let categories: [BudgetCategory]
    let currency: AppCurrency
    let onAddCategory: () -> Void

    var body: some View {
        Section {
            if categories.isEmpty {
                Text("No categories")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(categories) { category in
                    CategoryRowView(category: category, currency: currency)
                }
            }
        } header: {
            HStack {
                Text(type.title)

                Spacer()

                Button {
                    onAddCategory()
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("Add \(type.title) Category")
            }
        }
    }
}
