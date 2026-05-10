/* 
 * Budget Warden Core
 * Copyright (c) 2026 Lazarov & Co EOOD
 * Author: Nikola Lazarov
 *
 * Licensed under the Source-Available Educational License. 
 * See the LICENSE file in the project root for full terms.
 *
 */

import AppKit
import SwiftUI

let WINDOW_WIDTH: CGFloat = 760
let WINDOW_HEIGHT: CGFloat = 420

struct WelcomeView: View {
    @ObservedObject var store: BudgetStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @StateObject private var windowStore = BudgetWindowStore()
    @State private var shouldOpenWorkspaceAfterCreate = false
    @State private var budgetPendingRemoval: BudgetRow?

    var body: some View {
        HStack(spacing: 0) {
            WelcomeLeftColumn(
                onCreateBudget: {
                    shouldOpenWorkspaceAfterCreate = true
                    windowStore.showCreateBudget()
                },
                onOpenBudget: {
                    if store.openBudgetInPlace() {
                        openWorkspace()
                    }
                },
                onConfigureVault: {
                    shouldOpenWorkspaceAfterCreate = false
                    windowStore.showVaultSetup()
                }
            )
            WelcomeRightColumn(
                budgets: store.budgets,
                onSelectBudget: { budget in
                    store.selectBudget(budget)
                    openWorkspace()
                },
                onShowInFinder: showInFinder,
                onRemoveBudget: { budget in
                    budgetPendingRemoval = budget
                }
            )
        }
        .frame(
            minWidth: WINDOW_WIDTH,
            idealWidth: WINDOW_WIDTH,
            maxWidth: WINDOW_WIDTH,
            minHeight: WINDOW_HEIGHT,
            idealHeight: WINDOW_HEIGHT,
            maxHeight: WINDOW_HEIGHT
        )
        .background(WelcomeWindowConfigurator())
        .task {
            store.loadBudgets()
        }
        .focusedSceneValue(\.budgetWindowStore, windowStore)
        .sheet(isPresented: $windowStore.isCreatingBudget) {
            CreateBudgetView(
                store: store, 
                onSave: { draft in
                    if windowStore.createBudget(draft, store: store) {
                        openWorkspaceIfPossible()
                    }
                },
                onCancel: {
                    shouldOpenWorkspaceAfterCreate = false
                    windowStore.cancelCreateBudget()
                }
            )
            .frame(minWidth: 420)
        }
        .sheet(isPresented: $windowStore.isConfiguringVault) {
            VaultSetupView(
                initialLocalParentURL: store.configuredLocalVaultParentURL
            ) {
                windowStore.configureVault(preferICloud: true, store: store)
                openWorkspaceAfterCreateIfNeeded()
            } onChooseLocal: { parentURL in
                windowStore.configureVault(parentURL: parentURL, store: store)
                openWorkspaceAfterCreateIfNeeded()
            } onCancel: {
                shouldOpenWorkspaceAfterCreate = false
                windowStore.cancelVaultSetup(store: store)
            }
            .frame(minWidth: 440)
        }
        .sheet(isPresented: $windowStore.isShowingPreferences) {
            PreferencesView(
                selectedCurrency: $store.selectedCurrency,
                onClose: {
                    windowStore.closePreferences()
                }
            )
            .frame(minWidth: 360)
        }
        .alert(
            "Budget Warden",
            isPresented: errorBinding
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.presentedError ?? "")
        }
        .alert(
            "Remove Budget?",
            isPresented: removeBudgetConfirmationBinding,
            presenting: budgetPendingRemoval
        ) { budget in
            Button("Move to Trash", role: .destructive) {
                store.removeBudget(url: budget.url)
                budgetPendingRemoval = nil
            }

            Button("Cancel", role: .cancel) {
                budgetPendingRemoval = nil
            }
        } message: { budget in
            Text("Move \(budget.url.lastPathComponent) to Trash?")
        }
    }

    private func openWorkspaceIfPossible() {
        if store.selectedBudgetRow != nil {
            shouldOpenWorkspaceAfterCreate = false
            openWorkspace()
        }
    }

    private func openWorkspaceAfterCreateIfNeeded() {
        guard shouldOpenWorkspaceAfterCreate else {
            return
        }

        openWorkspaceIfPossible()
    }

    private func openWorkspace() {
        openWindow(id: "workspace")
        dismiss()
    }

    private func showInFinder(_ budget: BudgetRow) {
        NSWorkspace.shared.activateFileViewerSelecting([budget.url])
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { store.presentedError != nil },
            set: {
                if !$0 {
                    store.presentedError = nil
                }
            }
        )
    }

    private var removeBudgetConfirmationBinding: Binding<Bool> {
        Binding(
            get: { budgetPendingRemoval != nil },
            set: {
                if !$0 {
                    budgetPendingRemoval = nil
                }
            }
        )
    }
}

private struct WelcomeWindowConfigurator: NSViewRepresentable {
    private static let contentSize = NSSize(width: WINDOW_WIDTH, height: WINDOW_HEIGHT)

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        configureWindow(for: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        configureWindow(for: nsView)
    }

    private func configureWindow(for view: NSView) {
        DispatchQueue.main.async {
            guard let window = view.window else {
                return
            }

            window.styleMask.remove([.resizable, .miniaturizable])
            window.standardWindowButton(.miniaturizeButton)?.isHidden = true
            window.standardWindowButton(.zoomButton)?.isHidden = true
            window.collectionBehavior.remove([.fullScreenPrimary, .fullScreenAuxiliary])
            window.collectionBehavior.insert(.fullScreenNone)
            window.setContentSize(Self.contentSize)
            window.contentMinSize = Self.contentSize
            window.contentMaxSize = Self.contentSize
            window.minSize = window.frame.size
            window.maxSize = window.frame.size
        }
    }
}
