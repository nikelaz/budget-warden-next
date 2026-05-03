import SwiftUI

enum SidebarSection: Hashable {
    case budget
    case reporting
    case transactions

    var title: Swift.String {
        switch self {
        case .budget:
            return "Budget"
        case .reporting:
            return "Reporting"
        case .transactions:
            return "Transactions"
        }
    }

    var systemImage: Swift.String {
        switch self {
        case .budget:
            return "chart.pie"
        case .reporting:
            return "chart.xyaxis.line"
        case .transactions:
            return "list.bullet.rectangle"
        }
    }
}

struct SidebarView: View {
    @Binding var selectedSection: SidebarSection

    var body: some View {
        List(selection: $selectedSection) {
            sidebarButton(.budget)
            sidebarButton(.reporting)
            sidebarButton(.transactions)
        }
            .navigationTitle("Budget Warden")
            .frame(minWidth: 220)
    }

    private func sidebarButton(_ section: SidebarSection) -> some View {
        Label(
            section.title,
            systemImage: section.systemImage
        )
            .tag(section)
    }
}
