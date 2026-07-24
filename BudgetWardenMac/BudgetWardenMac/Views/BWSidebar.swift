/* 
 * Budget Warden
 * Copyright (c) 2026 Lazarov & Co EOOD
 * Author: Nikola Lazarov
 *
 * Licensed under the Source-Available Educational License. 
 * See the LICENSE file in the project root for full terms.
 */

import SwiftUI
import BWCore

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
            .accessibilityIdentifier("sidebar\(section.title)Button")
            .tag(section)
    }
}
