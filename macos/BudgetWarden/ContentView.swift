import SwiftUI

struct ContentView: View {
    @ObservedObject var store: BudgetStore
    @State private var selectedSection: BudgetSidebarSection = .budget

    var body: some View {
        NavigationSplitView {
            BudgetSidebarView(
                selectedSection: $selectedSection
            )
        } detail: {
            if let selectedBudget = store.selectedBudget {
                switch selectedSection {
                case .budget:
                    BudgetDetailView(
                        budgets: store.availableBudgets,
                        budget: selectedBudget,
                        selectedBudgetID: $store.selectedBudgetID,
                        onCreateBudget: store.showCreateBudget,
                        onAddCategory: store.addCategory,
                        onAddTransaction: store.addTransaction
                    )
                case .transactions:
                    TransactionsView(
                        budgets: store.availableBudgets,
                        budget: selectedBudget,
                        selectedBudgetID: $store.selectedBudgetID,
                        onCreateBudget: store.showCreateBudget,
                        onAddTransaction: store.addTransaction
                    )
                }
            } else {
                ContentUnavailableView(
                    "No Budget Selected",
                    systemImage: "creditcard.and.123"
                )
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            store.showCreateBudget()
                        } label: {
                            Label("Create New Budget", systemImage: "plus")
                        }
                    }
                }
            }
        }
        .task {
            store.loadBudgets()
        }
        .sheet(isPresented: $store.isCreatingBudget) {
            CreateBudgetView(
                onSave: store.createBudget,
                onCancel: store.cancelCreateBudget
            )
            .frame(minWidth: 420)
        }
        .sheet(isPresented: $store.isConfiguringVault) {
            VaultSetupView(
                initialLocalParentURL: store.configuredLocalVaultParentURL
            ) {
                store.configureVault(preferICloud: true)
            } onChooseLocal: { parentURL in
                store.configureVault(parentURL: parentURL)
            } onCancel: {
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
    ContentView(store: BudgetStore())
}
