/* 
 * Budget Warden Core
 * Copyright (c) 2026 Lazarov & Co EOOD
 * Author: Nikola Lazarov
 *
 * Licensed under the Source-Available Educational License. 
 * See the LICENSE file in the project root for full terms.
 *
 */

import Combine
import SwiftUI

@MainActor
final class BudgetWindowStore: ObservableObject {
    @Published var isCreatingBudget = false
    @Published var isConfiguringVault = false
    @Published var isShowingPreferences = false

    func showCreateBudget() {
        isCreatingBudget = true
    }

    func showVaultSetup() {
        isConfiguringVault = true
    }

    func showPreferences() {
        isShowingPreferences = true
    }

    func cancelCreateBudget() {
        isCreatingBudget = false
    }

    func cancelVaultSetup(store: BudgetStore) {
        isConfiguringVault = false
        store.cancelVaultSetup()
    }

    func closePreferences() {
        isShowingPreferences = false
    }

    func createBudget(_ draft: BudgetDraft, store: BudgetStore) -> Bool {
        if store.createBudget(draft) {
            isCreatingBudget = false
            return true
        }

        if store.presentedError == nil {
            isCreatingBudget = false
            isConfiguringVault = true
        }

        return false
    }

    func configureVault(preferICloud: Bool, store: BudgetStore) {
        store.configureVault(preferICloud: preferICloud)
        closeVaultSetupIfSuccessful(store: store)
    }

    func configureVault(parentURL: URL, store: BudgetStore) {
        store.configureVault(parentURL: parentURL)
        closeVaultSetupIfSuccessful(store: store)
    }

    private func closeVaultSetupIfSuccessful(store: BudgetStore) {
        if store.presentedError == nil {
            isConfiguringVault = false
        }
    }
}

private struct BudgetWindowStoreFocusedValueKey: FocusedValueKey {
    typealias Value = BudgetWindowStore
}

extension FocusedValues {
    var budgetWindowStore: BudgetWindowStore? {
        get { self[BudgetWindowStoreFocusedValueKey.self] }
        set { self[BudgetWindowStoreFocusedValueKey.self] = newValue }
    }
}
