import SwiftUI

struct MainWindow: Scene {
    let store: BudgetStore

    var body: some Scene {
        WindowGroup("Budget Warden", id: "workspace") {
            MainLayoutView(store: store)
        }
            .defaultSize(width: 1040, height: 700)
            .windowToolbarStyle(.unified)
            .commands {
                windowCommands
            }
    }

    @CommandsBuilder
    private var windowCommands: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Preferences...") {
                store.showPreferences()
            }
            .keyboardShortcut(",", modifiers: .command)
        }
        
        CommandGroup(after: .newItem) {
            Button("Configure Vault...") {
                store.showVaultSetup()
            }
        }
    }
}

