import SwiftUI

struct CategoryRowView: View {
    let category: BudgetCategory
    let currency: AppCurrency

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(category.title)
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
            "Planned \(category.amountPlanned.formattedMoneyAmount(currency: currency))",
            "Actual \(category.amountActual.formattedMoneyAmount(currency: currency))"
        ]

        if category.type == .savings || category.type == .debt {
            parts.append("Accumulated \(category.amountAccumulated.formattedMoneyAmount(currency: currency))")
        }

        return parts.joined(separator: " | ")
    }
}
