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

struct BWMainWindow: Scene {
    @EnvironmentObject var store: BWStore

    @StateObject private var windowStore = BWWindowStore()

    @State private var selectedSection: SidebarSection = .budget

    var body: some Scene {
        Window("Budget Warden", id: "window-main") {
            NavigationSplitView {
                SidebarView(
                    selectedSection: $selectedSection
                )
            }
            detail: {
                if store.currentBudget == nil {
                    ContentUnavailableView(
                        "No Budget Selected",
                        systemImage: "x.circle"
                    )
                }
                else {
                    switch selectedSection {
                        case .budget:
                            BudgetView(
                                store: store,
                                windowStore: windowStore
                            )
                        case .reporting:
                            Text("Reporting View")
                        case .transactions:
                            Text("Transactions View")
                    }
                }
            }
            .alert("Error", isPresented: $windowStore.isErrorState) {
                Button("OK") {
                    windowStore.clearError()
                }
            } message: {
                Text(windowStore.errorMessage)
            }
            .sheet(isPresented: $windowStore.isBudgetDialogOpen) {
                CreateBudgetView(onCreateSuccess: {})
                .environmentObject(windowStore)
                .frame(minWidth: 420)
            }
            .sheet(isPresented: $windowStore.isVaultConfigDialogOpen) {
                ConfigureVaultView()
                .environmentObject(store)
                .environmentObject(windowStore)
                .frame(minWidth: 420)
            }
        }
        .defaultSize(width: 1040, height: 700)
        // @TODO(Niki): Check what this does actually
        //.windowToolbarStyle(.unified)
        .defaultLaunchBehavior(.suppressed)
        .commands {
            BWCommands(windowStore: windowStore)
        }
    }
}
