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
