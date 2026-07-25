/*
 * Budget Warden
 * Copyright (c) 2026 Lazarov & Co EOOD
 * Author: Nikola Lazarov
 *
 * Licensed under the Source-Available Educational License.
 * See the LICENSE file in the project root for full terms.
 */

import SwiftUI

struct BWCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @FocusedValue(\.windowStore) private var windowStore

    let store: BWStore

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Preferences") {
                windowStore?.openPreferencesDialog()
            }
            .keyboardShortcut(",", modifiers: .command)
            .disabled(windowStore == nil)
        }

        CommandGroup(replacing: .newItem) {
            Button("New Budget", systemImage: "plus") {
                windowStore?.openBudgetDialog()
            }
            .keyboardShortcut("n", modifiers: [.command])
            .disabled(windowStore == nil)
        }

        CommandGroup(after: .newItem) {
            Button("Open Budget", systemImage: "folder") {
                guard let windowStore else { return }

                Task {
                    guard let url = await store.openFilePicker(windowStore: windowStore) else {
                        return
                    }

                    if await store.openBudget(at: url, windowStore: windowStore) {
                        openWindow(id: "window-main")
                        dismissWindow(id: "window-welcome")
                    }
                }
            }
            .keyboardShortcut("o", modifiers: [.command])
            .disabled(windowStore == nil)
        }
    }
}
