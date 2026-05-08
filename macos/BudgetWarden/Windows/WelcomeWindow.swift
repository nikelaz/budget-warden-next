import SwiftUI

struct WelcomeWindow: Scene {
    let store: BudgetStore

    var body: some Scene {
        WindowGroup("Budget Warden", id: "welcome") {
            WelcomeView(store: store)
                .containerBackground(.thinMaterial, for: .window)
        }
            .defaultSize(width: 760, height: 420)
            .defaultLaunchBehavior(.presented)
            .windowStyle(.hiddenTitleBar)
            .windowResizability(.contentSize)
            .commands {
                CommandGroup(replacing: .appSettings) {
                    Button("Preferences...") {
                        store.showPreferences(from: .welcome)
                    }
                    .keyboardShortcut(",", modifiers: .command)
                }
            }
    }
}
