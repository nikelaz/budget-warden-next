import SwiftUI

struct BudgetRowView: View {
    let budget: BudgetDocument

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

#Preview {
    BudgetRowView(
        budget: BudgetDocument(
            coreID: 1,
            url: URL(filePath: "/tmp/May 2026.budget"),
            title: "May 2026",
            categories: []
        )
    )
}
