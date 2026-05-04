import SwiftUI

struct MainLayoutView: View {
    @ObservedObject var store: BudgetStore
    @State private var selectedSection: SidebarSection = .budget

    var body: some View {
        NavigationSplitView {
            SidebarView(
                selectedSection: $selectedSection
            )
        } detail: {
            if let selectedBudget = store.selectedBudget {
                switch selectedSection {
                case .budget:
                    BudgetDetailView(
                        budgets: store.availableBudgets,
                        budget: selectedBudget,
                        currency: store.selectedCurrency,
                        selectedBudgetID: $store.selectedBudgetID,
                        onCreateBudget: store.showCreateBudget,
                        onAddCategory: store.addCategory,
                        onUpdateCategory: store.updateCategory,
                        onRemoveCategory: store.removeCategory,
                        onReorderCategories: store.reorderCategories,
                        onAddTransaction: store.addTransaction
                    )
                case .reporting:
                    ReportingView(
                        budgets: store.availableBudgets,
                        budget: selectedBudget,
                        currency: store.selectedCurrency,
                        selectedBudgetID: $store.selectedBudgetID,
                        onCreateBudget: store.showCreateBudget,
                        onAddTransaction: store.addTransaction
                    )
                case .transactions:
                    TransactionsView(
                        budgets: store.availableBudgets,
                        budget: selectedBudget,
                        currency: store.selectedCurrency,
                        selectedBudgetID: $store.selectedBudgetID,
                        onCreateBudget: store.showCreateBudget,
                        onAddTransaction: store.addTransaction,
                        onUpdateTransaction: store.updateTransaction,
                        onRemoveTransaction: store.removeTransaction
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
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            store.showPreferences()
                        } label: {
                            Label("Preferences", systemImage: "gearshape")
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
                store: store,
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
        .sheet(isPresented: $store.isShowingPreferences) {
            PreferencesView(
                selectedCurrency: $store.selectedCurrency,
                onClose: {
                    store.isShowingPreferences = false
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
