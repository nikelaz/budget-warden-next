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
    @Environment(\.scenePhase) private var scenePhase

    @StateObject private var windowStore = BWWindowStore()

    @State private var selectedSection: SidebarSection = .budget

    var body: some Scene {
        Window("Main Window", id: "window-main") {
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
                            .environmentObject(windowStore)
                        case .reporting:
                            BWReportingView(
                                store: store,
                                windowStore: windowStore
                            )
                        case .transactions:
                            BWTransactionsView(
                                store: store,
                                windowStore: windowStore
                            )
                            .environmentObject(windowStore)
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
            .alert("Vault Warning", isPresented: Binding(
                get: { store.vaultWarningMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        store.clearVaultWarning()
                    }
                }
            )) {
                Button("OK") {
                    store.clearVaultWarning()
                }
            } message: {
                Text(store.vaultWarningMessage ?? "")
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
            .sheet(isPresented: $windowStore.isPreferencesDialogOpen) {
                BWPreferencesView(
                    selectedCurrency: $store.selectedCurrency,
                    onClose: {
                        windowStore.closePreferencesDialog()
                    }
                )
                .frame(minWidth: 420)
            }
            .onDisappear {
                Task {
                    if let error = await store.flushPendingSaves() {
                        windowStore.setError(error)
                    }
                }
            }
            .onChange(of: scenePhase) { _, newPhase in
                guard newPhase != .active else {
                    return
                }

                Task {
                    if let error = await store.flushPendingSaves() {
                        windowStore.setError(error)
                    }
                }
            }
        }
        .defaultSize(width: 1280, height: 720)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        .commands {
            BWCommands(windowStore: windowStore)
        }
    }
}
