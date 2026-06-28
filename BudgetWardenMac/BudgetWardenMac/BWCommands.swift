/*
 * Budget Warden
 * Copyright (c) 2026 Lazarov & Co EOOD
 * Author: Nikola Lazarov
 *
 * Licensed under the Source-Available Educational License.
 * See the LICENSE file in the project root for full terms.
 *
 */

import SwiftUI
import BudgetWardenAppleCore

struct BWCommands: Commands {
    @EnvironmentObject var store: BWStore

    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var windowStore: BWWindowStore

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Preferences") {
                windowStore.openPreferencesDialog()
            }
            .keyboardShortcut(",", modifiers: .command)
        }

        CommandGroup(after: .appSettings) {
            Button("Configure Vault", systemImage: "externaldrive") {
                windowStore.openVaultConfigDialog()
            }
        }

        CommandGroup(replacing: .newItem) {
            Button("New Budget", systemImage: "plus") {
                windowStore.openBudgetDialog()
            }
            .keyboardShortcut("n", modifiers: [.command])
        }

        CommandGroup(after: .newItem) {
            Button("Open Budget", systemImage: "folder") {
                Task(priority: .userInitiated) {
                    if await store.openBudget(windowStore: windowStore) {
                        openWindow(id: "window-main")
                        dismissWindow(id: "window-welcome")
                    }
                }
            }
            .keyboardShortcut("o", modifiers: [.command])
        }       
    }
}
