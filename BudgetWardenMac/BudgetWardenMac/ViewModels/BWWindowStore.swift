/* 
 * Budget Warden
 * Copyright (c) 2026 Lazarov & Co EOOD
 * Author: Nikola Lazarov
 *
 * Licensed under the Source-Available Educational License. 
 * See the LICENSE file in the project root for full terms.
 *
 */

import Combine
import SwiftUI
import BudgetWardenAppleCore

@MainActor
class BWWindowStore: ObservableObject {
    @Published var isBudgetDialogOpen = false
    @Published var isVaultConfigDialogOpen = false
    @Published var isPreferencesDialogOpen = false
    @Published var isErrorState: Bool = false
    @Published var errorMessage: String = ""

    func openPreferencesDialog() {
        isPreferencesDialogOpen = true
    }

    func closePreferencesDialog() {
        isPreferencesDialogOpen = false
    }

    func openBudgetDialog() {
        isBudgetDialogOpen = true
    }

    func closeBudgetDialog() {
        isBudgetDialogOpen = false
    }

    func setError(_ err: BWError) {
        isErrorState = true
        errorMessage = err.localizedDescription
    }

    func clearError() {
        isErrorState = false
    }

    func openVaultConfigDialog() {
        isVaultConfigDialogOpen = true
    }

    func closeVaultConfigDialog() {
        isVaultConfigDialogOpen = false
    }
}
