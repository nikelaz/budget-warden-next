/* 
 * Budget Warden
 * Copyright (c) 2026 Lazarov & Co EOOD
 * Author: Nikola Lazarov
 *
 * Licensed under the Source-Available Educational License. 
 * See the LICENSE file in the project root for full terms.
 */

import SwiftUI
import AppIntents
import BWAppleCore

@main
struct BWApp: App {
    @StateObject private var store: BWStore

    init() {
        let store = BWStore()
        _store = StateObject(wrappedValue: store)
        BWIntentRegistration.register(library: store.library, googleDrive: store.googleDrive, iCloud: store.iCloud)
        BWAppShortcuts.updateAppShortcutParameters()
    }

    var body: some Scene {
        BWWindowWelcome()
            .environmentObject(store)
        BWWindowMain()
            .environmentObject(store)
        BWWindowCategoryTransactions()
            .environmentObject(store)
    }
}

struct BWAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: BWBudgetSummaryIntent(), phrases: [
            "Show my budget summary in \(.applicationName)",
            "Show the \(\.$budget) summary in \(.applicationName)",
            "How much is left in the \(\.$budget) budget in \(.applicationName)",
        ], shortTitle: "Budget Summary", systemImageName: "chart.bar.xaxis")
        AppShortcut(intent: BWDeleteBudgetIntent(), phrases: [
            "Delete the \(\.$budget) budget in \(.applicationName)",
        ], shortTitle: "Delete Budget", systemImageName: "trash")
        AppShortcut(intent: BWListCategoriesIntent(), phrases: [
            "Show categories for the \(\.$budget) budget in \(.applicationName)",
        ], shortTitle: "List Categories", systemImageName: "square.grid.2x2")
        AppShortcut(intent: BWListTransactionsIntent(), phrases: [
            "Show recent transactions in the \(\.$budget) budget in \(.applicationName)",
        ], shortTitle: "Recent Transactions", systemImageName: "list.bullet.rectangle.portrait")
        AppShortcut(intent: BWCreateBudgetIntent(), phrases: [
            "Create a \(\.$template) budget in \(.applicationName)",
        ], shortTitle: "Create Budget", systemImageName: "plus.circle")
        AppShortcut(intent: BWRenameBudgetIntent(), phrases: [
            "Rename the \(\.$budget) budget in \(.applicationName)",
        ], shortTitle: "Rename Budget", systemImageName: "pencil")
        AppShortcut(intent: BWManageCategoryIntent(), phrases: [
            "Manage categories in the \(\.$budget) budget in \(.applicationName)",
        ], shortTitle: "Manage Categories", systemImageName: "square.grid.2x2")
        AppShortcut(intent: BWManageTransactionIntent(), phrases: [
            "Manage transactions in the \(\.$budget) budget in \(.applicationName)",
        ], shortTitle: "Manage Transactions", systemImageName: "list.bullet.rectangle.portrait")
        AppShortcut(intent: BWCreateCategoryIntent(), phrases: [
            "Add a category to the \(\.$budget) budget in \(.applicationName)",
        ], shortTitle: "Add Category", systemImageName: "plus.square")
        AppShortcut(intent: BWCreateTransactionIntent(), phrases: [
            "Add a transaction to the \(\.$budget) budget in \(.applicationName)",
        ], shortTitle: "Add Transaction", systemImageName: "plus.circle")
    }
}
