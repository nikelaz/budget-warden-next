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
        ToolbarItemGroup(placement: .principal) {
            Menu {
                ForEach(budgets) { budget in
                    Button {
                        selectedBudgetID = budget.id
                    } label: {
                        if selectedBudgetID == budget.id {
                            Label(budget.title, systemImage: "checkmark")
                        } else {
                            Text(budget.title)
                        }
                    }
                }

                Divider()

                Button {
                    onCreateBudget()
                } label: {
                    Label("New Budget", systemImage: "plus")
                }
            } label: {
                Text(selectedBudgetTitle)
            }
        }
    }

    private var selectedBudgetTitle: Swift.String {
        budgets.first(where: { $0.id == selectedBudgetID })?.title ?? "Budget"
    }
}
