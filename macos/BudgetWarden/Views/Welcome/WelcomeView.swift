import AppKit
import SwiftUI

let WINDOW_WIDTH: CGFloat = 760
let WINDOW_HEIGHT: CGFloat = 420

struct WelcomeView: View {
    @ObservedObject var store: BudgetStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @State private var shouldOpenWorkspaceAfterCreate = false
    @State private var budgetPendingRemoval: BudgetDocument?
    private let dialogHost = BudgetDialogHost.welcome

    var body: some View {
        HStack(spacing: 0) {
            WelcomeLeftColumn(
                onCreateBudget: {
                    shouldOpenWorkspaceAfterCreate = true
                    store.showCreateBudget(from: dialogHost)
                },
                onOpenBudget: {
                    if store.openBudgetInPlace() {
                        openWorkspace()
                    }
                },
                onConfigureVault: {
                    shouldOpenWorkspaceAfterCreate = false
                    store.showVaultSetup(from: dialogHost)
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
        .sheet(isPresented: dialogBinding(\.isCreatingBudget, dismiss: store.cancelCreateBudget)) {
            CreateBudgetView(
                store: store, 
                onSave: { draft in
                    store.createBudget(draft)
                    openWorkspaceIfPossible()
                },
                onCancel: {
                    shouldOpenWorkspaceAfterCreate = false
                    store.cancelCreateBudget()
                }
            )
            .frame(minWidth: 420)
        }
        .sheet(isPresented: dialogBinding(\.isConfiguringVault, dismiss: store.cancelVaultSetup)) {
            VaultSetupView(
                initialLocalParentURL: store.configuredLocalVaultParentURL
            ) {
                store.configureVault(preferICloud: true)
                openWorkspaceAfterCreateIfNeeded()
            } onChooseLocal: { parentURL in
                store.configureVault(parentURL: parentURL)
                openWorkspaceAfterCreateIfNeeded()
            } onCancel: {
                shouldOpenWorkspaceAfterCreate = false
                store.cancelVaultSetup()
            }
            .frame(minWidth: 440)
        }
        .sheet(isPresented: dialogBinding(\.isShowingPreferences, dismiss: store.closePreferences)) {
            PreferencesView(
                selectedCurrency: $store.selectedCurrency,
                onClose: {
                    store.closePreferences()
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
                store.removeBudget(budget)
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
        if store.selectedBudget != nil {
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

    private func showInFinder(_ budget: BudgetDocument) {
        NSWorkspace.shared.activateFileViewerSelecting([budget.url])
    }

    private func dialogBinding(
        _ keyPath: KeyPath<BudgetStore, Bool>,
        dismiss: @escaping () -> Void
    ) -> Binding<Bool> {
        Binding(
            get: {
                store[keyPath: keyPath] && store.dialogHost == dialogHost
            },
            set: { isPresented in
                if !isPresented && store.dialogHost == dialogHost {
                    dismiss()
                }
            }
        )
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
