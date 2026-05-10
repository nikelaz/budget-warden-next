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
final class BWWindowStore: ObservableObject {
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

    func cancelVaultSetup(store: BWStore) {
        isConfiguringVault = false
        store.cancelVaultSetup()
    }

    func closePreferences() {
        isShowingPreferences = false
    }

    func createBudget(_ draft: BudgetDraft, store: BWStore) -> Bool {
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

    func configureVault(preferICloud: Bool, store: BWStore) {
        store.configureVault(preferICloud: preferICloud)
        closeVaultSetupIfSuccessful(store: store)
    }

    func configureVault(parentURL: URL, store: BWStore) {
        store.configureVault(parentURL: parentURL)
        closeVaultSetupIfSuccessful(store: store)
    }

    private func closeVaultSetupIfSuccessful(store: BWStore) {
        if store.presentedError == nil {
            isConfiguringVault = false
        }
    }
}

private struct BudgetWindowStoreFocusedValueKey: FocusedValueKey {
    typealias Value = BWWindowStore
}

extension FocusedValues {
    var budgetWindowStore: BWWindowStore? {
        get { self[BudgetWindowStoreFocusedValueKey.self] }
        set { self[BudgetWindowStoreFocusedValueKey.self] = newValue }
    }
}
