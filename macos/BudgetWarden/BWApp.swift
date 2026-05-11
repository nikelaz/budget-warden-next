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
        let fileContentsOptional = BWFiles.openAndReadFile();

        if fileContentsOptional == nil {
            print("file contents are nil")
            return
        }

        let fileContents = fileContentsOptional!

        print(fileContents)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
