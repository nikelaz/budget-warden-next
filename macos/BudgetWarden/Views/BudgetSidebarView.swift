import SwiftUI

enum BudgetSidebarSection: Hashable {
    case budget
    case transactions

    var title: Swift.String {
        switch self {
        case .budget:
            return "Budget"
        case .transactions:
            return "Transactions"
        }
    }

    var systemImage: Swift.String {
        switch self {
        case .budget:
            return "chart.pie"
        case .transactions:
            return "list.bullet.rectangle"
        }
    }
}

struct BudgetSidebarView: View {
    @Binding var selectedSection: BudgetSidebarSection

    var body: some View {
        List(selection: $selectedSection) {
            sidebarButton(.budget)
            sidebarButton(.transactions)
        }
        .navigationTitle("Budget Warden")
        .frame(minWidth: 220)
    }

    private func sidebarButton(_ section: BudgetSidebarSection) -> some View {
        Label(section.title, systemImage: section.systemImage)
            .tag(section)
    }
}

struct BudgetTopToolbar: ToolbarContent {
    let budgets: [BudgetDocument]
    @Binding var selectedBudgetID: BudgetDocument.ID?
    let onCreateBudget: () -> Void

    var body: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            HStack(spacing: 8) {
                Picker("Budget", selection: $selectedBudgetID) {
                    ForEach(budgets) { budget in
                        Text(budget.title)
                            .tag(Optional(budget.id))
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(minWidth: 140)

                Button {
                    onCreateBudget()
                } label: {
                    Image(systemName: "plus")
                }
                .help("Create New Budget")
            }
        }
    }
}
