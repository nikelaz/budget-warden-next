/* 
 * Budget Warden
 * Copyright (c) 2026 Lazarov & Co EOOD
 * Author: Nikola Lazarov
 *
 * Licensed under the Source-Available Educational License. 
 * See the LICENSE file in the project root for full terms.
 *
 */

import SwiftUI

struct WelcomeRightColumn: View {
    let store: BWStore
    let openMainWindow: () -> Void
    let onRemoveBudget: (BudgetRow) -> Void

    var body: some View {
        VStack(alignment: .center, spacing: 10) {
            Spacer()
            
            Text("Budgets in Vault")
                .font(.headline)

            if !store.budgetsLoaded {
                ProgressView()
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if store.budgets.isEmpty {
                ContentUnavailableView(
                    "No Budgets",
                    systemImage: "tray",
                    description: Text("Create a new budget to get started")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                     VStack(spacing: 5) {
                         ForEach(store.budgets) { budget in
                             Button {
                                 store.selectBudget(budget)
                                 openMainWindow()
                             } label: {
                                 BudgetRowView(budget: budget)
                                     .frame(maxWidth: .infinity, alignment: .leading)
                             }
                             .contextMenu {
                                 Button {
                                     NSWorkspace.shared.activateFileViewerSelecting([budget.url])
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
