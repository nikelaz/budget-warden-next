/*
 * Budget Warden
 * Copyright (c) 2026 Lazarov & Co EOOD
 * Author: Nikola Lazarov
 *
 * Licensed under the Source-Available Educational License.
 * See the LICENSE file in the project root for full terms.
 */

import SwiftUI

struct BWWindowMain: Scene {
    @EnvironmentObject private var store: BWStore
    @StateObject private var windowStore = BWWindowStore()
    @State private var selectedSection: SidebarSection = .budget

    var body: some Scene {
        Window("Budget Warden", id: "window-main") {
            NavigationSplitView {
                SidebarView(selectedSection: $selectedSection)
            } detail: {
                if store.currentBudget == nil {
                    ContentUnavailableView("No Budget Selected", systemImage: "doc")
                } else {
                    switch selectedSection {
                    case .budget:
                        BudgetView(store: store, windowStore: windowStore)
                            .environmentObject(windowStore)
                    case .reporting:
                        BWReportingView(store: store, windowStore: windowStore)
                    case .transactions:
                        BWTransactionsView(store: store, windowStore: windowStore)
                            .environmentObject(windowStore)
                    }
                }
            }
            .onOpenURL { url in
                Task { _ = await store.openBudget(at: url, windowStore: windowStore) }
            }
            .alert("Error", isPresented: $windowStore.isErrorState) {
                Button("OK") { windowStore.clearError() }
            } message: {
                Text(windowStore.errorMessage)
            }
            .sheet(isPresented: $windowStore.isBudgetDialogOpen) {
                CreateBudgetView(onCreateSuccess: windowStore.closeBudgetDialog)
                    .environmentObject(windowStore)
                    .frame(minWidth: 420)
            }
            .sheet(isPresented: $windowStore.isPreferencesDialogOpen) {
                BWPreferencesView(
                    selectedCurrency: $store.selectedCurrency,
                    onClose: windowStore.closePreferencesDialog
                )
                .frame(minWidth: 420)
            }
            .focusedSceneValue(\.windowStore, windowStore)
        }
        .defaultSize(width: 1280, height: 800)
        .defaultLaunchBehavior(.suppressed)
        .commands { BWCommands(store: store) }
    }
}
