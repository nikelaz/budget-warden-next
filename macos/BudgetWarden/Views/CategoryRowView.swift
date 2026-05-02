import SwiftUI

struct CategoryRowView: View {
    let category: BudgetCategory

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
            "Planned \(category.amountPlanned)",
            "Actual \(category.amountActual)"
        ]

        if category.type == .savings || category.type == .debt {
            parts.append("Accumulated \(category.amountAccumulated)")
        }

        return parts.joined(separator: " | ")
    }
}

