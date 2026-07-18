/*
 * Budget Warden
 * Copyright (c) 2026 Lazarov & Co EOOD
 * Author: Nikola Lazarov
 *
 * Licensed under the Source-Available Educational License.
 * See the LICENSE file in the project root for full terms.
 */

import Combine
import Foundation

@MainActor
final class BWWindowStore: ObservableObject {
    @Published var isBudgetDialogOpen = false
    @Published var isPreferencesDialogOpen = false
    @Published var isErrorState = false
    @Published var errorMessage = ""

    func openPreferencesDialog() { isPreferencesDialogOpen = true }
    func closePreferencesDialog() { isPreferencesDialogOpen = false }
    func openBudgetDialog() { isBudgetDialogOpen = true }
    func closeBudgetDialog() { isBudgetDialogOpen = false }

    func setError(_ error: Error) {
        errorMessage = error.localizedDescription
        isErrorState = true
    }

    func clearError() {
        isErrorState = false
        errorMessage = ""
    }
}
