import SwiftUI

struct BudgetRowView: View {
    let budget: BudgetDocument

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(budget.title)
                .font(.headline)

            Text(budget.period)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    BudgetRowView(
        budget: BudgetDocument(
            id: URL(filePath: "/tmp/May 2026.budget"),
            url: URL(filePath: "/tmp/May 2026.budget"),
            title: "May 2026",
            periodStart: BWDate(year: 2026, month: 5, day: 1),
            periodEnd: BWDate(year: 2026, month: 5, day: 31),
            categories: []
        )
    )
}
