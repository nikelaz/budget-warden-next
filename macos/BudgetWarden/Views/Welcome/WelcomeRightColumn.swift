import SwiftUI

struct WelcomeRightColumn: View {
    let budgets: [BudgetDocument]
    let onSelectBudget: (BudgetDocument) -> Void
    let onShowInFinder: (BudgetDocument) -> Void
    let onRemoveBudget: (BudgetDocument) -> Void

    var body: some View {
        VStack(alignment: .center, spacing: 10) {
            Spacer()
            
            Text("Budgets in Vault")
                .font(.headline)

            if budgets.isEmpty {
                ContentUnavailableView(
                    "No Budgets",
                    systemImage: "tray",
                    description: Text("Create a new budget to get starteds")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                     VStack(spacing: 5) {
                         ForEach(budgets) { budget in
                             Button {
                                 onSelectBudget(budget)
                             } label: {
                                 BudgetRowView(budget: budget)
                                     .frame(maxWidth: .infinity, alignment: .leading)
                             }
                             .accessibilityIdentifier("budget-row-\(budget.title)")
                             .contextMenu {
                                 Button {
                                     onShowInFinder(budget)
                                 } label: {
                                     Label("Show in Finder", systemImage: "folder")
                                 }

                                 Button(role: .destructive) {
                                     onRemoveBudget(budget)
                                 } label: {
                                     Label("Remove from Vault", systemImage: "trash")
                                 }
                             }
                         }
                     }
                 }
                .padding(.bottom, 30)
            }
            
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity)
    }
}
