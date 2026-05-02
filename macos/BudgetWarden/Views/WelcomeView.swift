import AppKit
import SwiftUI

struct WelcomeView: View {
    @ObservedObject var store: BudgetStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @State private var shouldOpenWorkspaceAfterCreate = false
    @State private var budgetPendingRemoval: BudgetDocument?

    var body: some View {
        HStack(spacing: 0) {
            leftColumn
            rightColumn
        }
        .frame(
            minWidth: 760,
            idealWidth: 760,
            maxWidth: 760,
            minHeight: 420,
            idealHeight: 420,
            maxHeight: 420
        )
        .background(WelcomeWindowConfigurator())
        .task {
            store.loadBudgets()
        }
        .sheet(isPresented: $store.isCreatingBudget) {
            CreateBudgetView(
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
        .sheet(isPresented: $store.isConfiguringVault) {
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

    private var leftColumn: some View {
        VStack(alignment: .center, spacing: 20) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 130, height: 130)
                .accessibilityHidden(true)
            
            Text("Budget Warden")
                .font(.largeTitle)
                .fontWeight(.semibold)
            
            VStack(alignment: .center, spacing: 10) {
                Button("Create New Budget", systemImage: "plus") {
                    shouldOpenWorkspaceAfterCreate = true
                    store.showCreateBudget()
                }
                
                Button("Open Budget", systemImage: "folder") {
                    if store.openBudgetInPlace() {
                        openWorkspace()
                    }
                }
                
                Button("Configure Vault", systemImage: "externaldrive") {
                    shouldOpenWorkspaceAfterCreate = false
                    store.showVaultSetup()
                }
            }
            
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity)
    }

    private var rightColumn: some View {
        VStack(alignment: .center, spacing: 10) {
            Spacer()
            
            Text("Budgets in Vault")
                .font(.headline)

            if store.budgets.isEmpty {
                ContentUnavailableView(
                    "No Vault Budgets",
                    systemImage: "tray",
                    description: Text("Configure a vault or create a budget to see it here.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                     VStack(spacing: 5) {
                         ForEach(store.budgets) { budget in
                             Button {
                                 store.selectBudget(budget)
                                 openWorkspace()
                             } label: {
                                 BudgetRowView(budget: budget)
                                     .frame(maxWidth: .infinity, alignment: .leading)
                             }
                             .contextMenu {
                                 Button {
                                     showInFinder(budget)
                                 } label: {
                                     Label("Show in Finder", systemImage: "folder")
                                 }

                                 Button(role: .destructive) {
                                     budgetPendingRemoval = budget
                                 } label: {
                                     Label("Remove from Vault", systemImage: "trash")
                                 }
                             }
                         }
                     }
                 }
                .padding(.bottom, 30)
            }
            
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity)
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

#Preview {
    WelcomeView(store: BudgetStore())
}

private struct WelcomeWindowConfigurator: NSViewRepresentable {
    private static let contentSize = NSSize(width: 760, height: 420)

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
