/*
 * Budget Warden
 * Copyright (c) 2026 Lazarov & Co EOOD
 * Author: Nikola Lazarov
 *
 * Licensed under the Source-Available Educational License.
 * See the LICENSE file in the project root for full terms.
 *
 */

import Foundation
import Combine

@MainActor
class BWStore: ObservableObject {
    @Published var budgetsInVault: [BWBudget] = []
    @Published var budgetsInVaultLoaded: Bool = false
    @Published var isVaultNotSet: Bool = false

    private var vault: BWVault = BWVault()
    
    func selectVaultFolder() async {
        let selectVaultRes = await vault.selectVaultFolder()
       
        switch selectVaultRes {
            case .success:
                await loadBudgetsFromVault()
            case .failure:
                break
        }
    }

    func loadBudgetsFromVault() async {
        budgetsInVault = []
        budgetsInVaultLoaded = false
        isVaultNotSet = false

        let vaultReadRes = await vault.readBudgetsFromVault()

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
