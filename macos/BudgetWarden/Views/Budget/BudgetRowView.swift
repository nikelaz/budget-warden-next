import SwiftUI

struct BudgetRowView: View {
    let budget: BudgetRow

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(budget.title)
                .font(.headline)

            Text(budget.url.lastPathComponent)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}
