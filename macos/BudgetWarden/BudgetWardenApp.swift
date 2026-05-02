//
//  BudgetWardenApp.swift
//  BudgetWarden
//
//  Created by Nikola Lazarov on 1.05.26.
//

import SwiftUI

@main
struct BudgetWardenApp: App {
    @StateObject private var store = BudgetStore()

    var body: some Scene {
        WindowGroup {
            WelcomeView(store: store)
                .containerBackground(.thinMaterial, for: .window)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 760, height: 420)
        .windowResizability(.contentSize)

        WindowGroup("Budget Warden", id: "workspace") {
            ContentView(store: store)
        }
        .defaultSize(width: 1040, height: 700)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Configure Vault...") {
                    store.showVaultSetup()
                }
            }
        }
    }
}
