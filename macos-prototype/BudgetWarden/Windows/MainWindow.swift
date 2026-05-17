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

struct MainWindow: Scene {
    let store: BWStore

    var body: some Scene {
        WindowGroup("Budget Warden", id: "main-window") {
            MainLayoutView(store: store)
        }
            .defaultSize(width: 1040, height: 700)
            .defaultLaunchBehavior(.suppressed)
            .windowToolbarStyle(.unified)
    }
}
