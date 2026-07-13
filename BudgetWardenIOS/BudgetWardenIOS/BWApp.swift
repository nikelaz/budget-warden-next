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
import UIKit

@main
struct BWApp: App {
    @UIApplicationDelegateAdaptor(BWAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            BWRootView()
        }
    }
}
