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
import BudgetWardenAppleCore
import CloudKit

struct BWWindowMain: Scene {
    @EnvironmentObject var store: BWStore
    @Environment(\.openWindow) private var openWindow
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
            .onOpenURL { url in
                Task(priority: .userInitiated) {
                    if await store.openBudget(at: url, windowStore: windowStore) {
                        openWindow(id: "window-main")
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .budgetWardenAcceptedCloudShare)) { notification in
                guard let recordID = notification.object as? CKRecord.ID else {
                    return
                }

                Task {
                    await openAcceptedCloudShare(recordID: recordID)
                }
            }
            .task {
                if let recordID = BWPendingCloudShare.recordID {
                    await openAcceptedCloudShare(recordID: recordID)
                }
            }
            .onAppear {
                store.setAutoRefreshActive(scenePhase == .active)
                updateAutoRefreshDialogBlocker()
            }
            .onDisappear {
                store.setAutoRefreshSuspended(false, reason: "mainWindowDialog")
            }
            .onChange(of: scenePhase) { _, phase in
                store.setAutoRefreshActive(phase == .active)
            }
            .onChange(of: hasAutoRefreshBlockingDialog) { _, _ in
                updateAutoRefreshDialogBlocker()
            }
        }
        .defaultSize(width: 1280, height: 720)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        .commands {
            BWCommands(windowStore: windowStore)
        }
    }

    private var hasAutoRefreshBlockingDialog: Bool {
        windowStore.isBudgetDialogOpen
            || windowStore.isVaultConfigDialogOpen
            || windowStore.isPreferencesDialogOpen
            || windowStore.isErrorState
    }

    private func updateAutoRefreshDialogBlocker() {
        store.setAutoRefreshSuspended(
            hasAutoRefreshBlockingDialog,
            reason: "mainWindowDialog"
        )
    }

    private func openAcceptedCloudShare(recordID: CKRecord.ID) async {
        guard await store.openAcceptedCloudShare(recordID: recordID) else {
            return
        }

        BWPendingCloudShare.clear(recordID: recordID)
        openWindow(id: "window-main")
    }
}
