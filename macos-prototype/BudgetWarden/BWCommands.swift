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

struct BWCommands: Commands {
    @FocusedValue(\.budgetWindowStore) private var windowStore

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Preferences") {
                windowStore?.showPreferences()
            }
            .disabled(windowStore == nil)
            .keyboardShortcut(",", modifiers: .command)
        }
        
        CommandGroup(after: .newItem) {
            Button("Configure Vault") {
                windowStore?.showVaultSetup()
            }
            .disabled(windowStore == nil)
        }
    }
}
