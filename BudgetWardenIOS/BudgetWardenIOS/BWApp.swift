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
        BWUITestSupport.resetStateIfRequested()
    }

    var body: some Scene {
        WindowGroup {
            BWRootView()
        }
    }
}

enum BWUITestSupport {
    nonisolated static let testingArgument = "-BWUITesting"
    nonisolated static let resetStateArgument = "-BWResetUITestState"

    nonisolated static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains(testingArgument)
    }

    static func resetStateIfRequested() {
        guard isEnabled,
              ProcessInfo.processInfo.arguments.contains(resetStateArgument)
        else {
            return
        }

        UserDefaults.standard.removeObject(forKey: "BWI_LAST_OPENED_BUDGET_ID")
        UserDefaults.standard.removeObject(forKey: "BWI_CURRENCY")
        BWVault.resetUITestState()
    }
}
