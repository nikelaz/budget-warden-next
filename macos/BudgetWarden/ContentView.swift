import SwiftUI

struct ContentView: View {
    @StateObject private var store = BudgetStore()

    var body: some View {
        NavigationSplitView {
            BudgetSidebarView(
                budgets: store.budgets,
                selectedBudgetID: $store.selectedBudgetID,
                onCreateBudget: store.showCreateBudget
            )
        } detail: {
            if let selectedBudget = store.selectedBudget {
                BudgetDetailView(
                    budget: selectedBudget,
                    onAddCategory: store.addCategory
                )
            } else {
                ContentUnavailableView(
                    "No Budget Selected",
                    systemImage: "creditcard.and.123"
                )
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
            VaultSetupView {
                store.configureVault(preferICloud: true)
            } onChooseLocal: {
                store.configureVault(preferICloud: false)
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
    ContentView()
}
