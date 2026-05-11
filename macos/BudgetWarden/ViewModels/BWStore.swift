import Foundation
import Combine

@MainActor
class BWStore: ObservableObject {
    @Published var budgetsInVault: [BWBudget] = []
    @Published var budgetsInVaultLoaded: Bool = false
    @Published var isVaultNotSet: Bool = false

    private let vault: BWVault = BWVault()

    func loadBudgetsFromVault() {
        budgetsInVault = []
        budgetsInVaultLoaded = false
        isVaultNotSet = false

        let vaultReadRes = vault.readBudgetsFromVault()

        switch vaultReadRes {
            case .failure:
                isVaultNotSet = true
                return
            case .success(let budgets):
                budgetsInVault = budgets
                budgetsInVaultLoaded = true
        }
    }
}
