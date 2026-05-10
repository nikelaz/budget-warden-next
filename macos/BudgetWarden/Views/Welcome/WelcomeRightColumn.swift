/* 
 * Budget Warden Core
 * Copyright (c) 2026 Lazarov & Co EOOD
 * Author: Nikola Lazarov
 *
 * Licensed under the Source-Available Educational License. 
 * See the LICENSE file in the project root for full terms.
 *
 */

import SwiftUI

struct WelcomeRightColumn: View {
    let budgets: [BudgetRow]
    let isLoadingBudgets: Bool
    let onSelectBudget: (BudgetRow) -> Void
    let onShowInFinder: (BudgetRow) -> Void
    let onRemoveBudget: (BudgetRow) -> Void

    var body: some View {
        VStack(alignment: .center, spacing: 10) {
            Spacer()
            
            Text("Budgets in Vault")
                .font(.headline)

            if isLoadingBudgets {
                ProgressView()
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if budgets.isEmpty {
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
            }
            
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity)
    }
}
