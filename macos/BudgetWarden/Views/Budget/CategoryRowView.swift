import SwiftUI

struct CategoryRowView: View {
    @ObservedObject var store: BudgetStore
    let budgetURL: URL
    let categoryID: Int
    let currency: AppCurrency

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(store.categoryTitle(categoryID, in: budgetURL))
                .font(.headline)
                .fontWeight(.medium)

            Text(summary)
                .font(.body)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private var summary: Swift.String {
        var parts = [
            "Planned \(store.categoryAmount(categoryID, field: .planned, in: budgetURL).formattedMoneyAmount(currency: currency))",
            "Actual \(store.categoryAmount(categoryID, field: .actual, in: budgetURL).formattedMoneyAmount(currency: currency))"
        ]

        if store.categoryType(categoryID, in: budgetURL) == .savings || store.categoryType(categoryID, in: budgetURL) == .debt {
            parts.append("Accumulated \(store.categoryAmount(categoryID, field: .accumulated, in: budgetURL).formattedMoneyAmount(currency: currency))")
        }

        return parts.joined(separator: " | ")
    }
}
