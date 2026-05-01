import SwiftUI

struct BudgetSidebarView: View {
    let budgets: [BudgetDocument]
    @Binding var selectedBudgetID: BudgetDocument.ID?
    let onCreateBudget: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            List(budgets, selection: $selectedBudgetID) { budget in
                BudgetRowView(budget: budget)
            }

            Divider()

            Button {
                onCreateBudget()
            } label: {
                Label("Create New Budget", systemImage: "plus")
            }
            .buttonStyle(.borderless)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        }
        .navigationTitle("Budgets")
        .frame(minWidth: 220)
    }
}
