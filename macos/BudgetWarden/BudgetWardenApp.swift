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

@main
struct BudgetWardenApp: App {
    @StateObject private var store = BudgetStore()

    var body: some Scene {
        WelcomeWindow(store: store)
        MainWindow(store: store)
            .commands {
                BWCommands()
            }
    }
}
