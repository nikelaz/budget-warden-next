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
    @StateObject private var store = BWStore()

    var body: some Scene {
        BWWelcomeWindow()
            .environmentObject(store)
    }
}
