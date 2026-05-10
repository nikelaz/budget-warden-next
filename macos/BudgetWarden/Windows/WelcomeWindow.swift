/* 
 * Budget Warden Core
 * Copyright (c) 2026 Lazarov & Co EOOD
 * Author: Nikola Lazarov
 *
 * Licensed under the Source-Available Educational License. 
 * See the LICENSE file in the project root for full terms.
 *
 */

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
    }
}
