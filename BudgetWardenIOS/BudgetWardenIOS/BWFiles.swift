/*
 * Budget Warden
 * Copyright (c) 2026 Lazarov & Co EOOD
 * Author: Nikola Lazarov
 *
 * Licensed under the Source-Available Educational License.
 * See the LICENSE file in the project root for full terms.
 *
 */

import AppleCore
import Foundation

enum BWFiles {
    nonisolated static func saveFile(url: URL, contents: String) -> Result<Void, BWError> {
        let didStartAccessing = url.startAccessingSecurityScopedResource()

        defer {
            if didStartAccessing {
                url.stopAccessingSecurityScopedResource()
            }
        }

        do {
            try contents.write(to: url, atomically: true, encoding: .utf8)
            return .success(())
        }
        catch {
            return .failure(.savingFile(underlying: error))
        }
    }
}
