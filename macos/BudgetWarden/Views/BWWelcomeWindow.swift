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

private let WINDOW_WIDTH: CGFloat = 760
private let WINDOW_HEIGHT: CGFloat = 420

struct BWWelcomeWindow: Scene { 
    @EnvironmentObject var store: BWStore

    var body: some Scene {
        WindowGroup("Budget Warden", id: "welcome") {
            HStack(spacing: 30) {
                Text("Budget Warden")

                if store.isVaultNotSet {
                    Text("Vault is not set")
                } else if !store.budgetsInVaultLoaded {
                    ProgressView("Loading budgets...")
                } else {
                    List(store.budgetsInVault, id: \.id) { budget in
                        Text(budget.title)
                    }
                }
            }
            .frame(
                minWidth: WINDOW_WIDTH,
                idealWidth: WINDOW_WIDTH,
                maxWidth: WINDOW_WIDTH,
                minHeight: WINDOW_HEIGHT,
                idealHeight: WINDOW_HEIGHT,
                maxHeight: WINDOW_HEIGHT
            )
            .containerBackground(.thinMaterial, for: .window)
            .task {
                store.loadBudgetsFromVault()
            }
        }
        .defaultSize(width: WINDOW_WIDTH, height: WINDOW_HEIGHT)
        .defaultLaunchBehavior(.presented)
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
    }
}
