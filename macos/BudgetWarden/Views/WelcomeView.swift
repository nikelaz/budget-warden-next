import AppKit
import SwiftUI

struct WelcomeView: View {
    @ObservedObject var store: BudgetStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @State private var shouldOpenWorkspaceAfterCreate = false

    var body: some View {
        HStack(spacing: 0) {
            actionPane

            Divider()

            vaultBudgetPane
        }
        .frame(minWidth: 680, minHeight: 380)
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
            VaultSetupView {
                store.configureVault(preferICloud: true)
                openWorkspaceAfterCreateIfNeeded()
            } onChooseLocal: {
                store.configureVault(preferICloud: false)
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
    }

    private var actionPane: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 88, height: 88)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text("Budget Warden")
                    .font(.largeTitle)
                    .fontWeight(.semibold)

                Text("Choose a budget to begin.")
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                welcomeButton("Create New Budget", systemImage: "plus") {
                    shouldOpenWorkspaceAfterCreate = true
                    store.showCreateBudget()
                }

                welcomeButton("Open Budget", systemImage: "folder") {
                    if store.openBudgetInPlace() {
                        openWorkspace()
                    }
                }

                welcomeButton("Configure Vault", systemImage: "externaldrive") {
                    shouldOpenWorkspaceAfterCreate = false
                    store.showVaultSetup()
                }
            }
            .padding(.top, 6)

            Spacer()
        }
        .padding(32)
        .frame(minWidth: 310, idealWidth: 310, maxWidth: 310, maxHeight: .infinity, alignment: .topLeading)
    }

    private var vaultBudgetPane: some View {
        VStack(alignment: .leading, spacing: 12) {
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
                List(store.budgets) { budget in
                    Button {
                        store.selectBudget(budget)
                        openWorkspace()
                    } label: {
                        BudgetRowView(budget: budget)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.inset)
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func welcomeButton(
        _ title: Swift.String,
        systemImage: Swift.String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .controlSize(.large)
        .buttonStyle(.borderless)
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
}

#Preview {
    WelcomeView(store: BudgetStore())
}
