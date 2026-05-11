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

@main
struct BWApp: App {
    init() {
        var vault = BWVault()

        let start = CFAbsoluteTimeGetCurrent()
        vault.readBudgetsFromVault()
        print("Took \((CFAbsoluteTimeGetCurrent() - start) * 1000) ms")
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
