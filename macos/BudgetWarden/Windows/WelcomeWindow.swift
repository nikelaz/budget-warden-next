import SwiftUI

struct WelcomeWindow: Scene {
    let store: BudgetStore

    var body: some Scene {
        WindowGroup {
            WelcomeView(store: store)
                .containerBackground(.thinMaterial, for: .window)
        }
            .defaultSize(width: 760, height: 420)
            .windowStyle(.hiddenTitleBar)
            .windowResizability(.contentSize)
            .commands {
                CommandGroup(replacing: .appSettings) {
                    Button("Preferences...") {
                        store.showPreferences()
                    }
                    .keyboardShortcut(",", modifiers: .command)
                }
            }
    }
}
