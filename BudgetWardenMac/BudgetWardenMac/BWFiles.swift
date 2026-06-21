/* 
 * Budget Warden
 * Copyright (c) 2026 Lazarov & Co EOOD
 * Author: Nikola Lazarov
 *
 * Licensed under the Source-Available Educational License. 
 * See the LICENSE file in the project root for full terms.
 *
 */

import AppKit
import UniformTypeIdentifiers
import AppleCore

private let budgetFileType = UTType(filenameExtension: "budget") ?? .data

class BWFiles {
    static func openAndReadFile() -> Result<(contents: String, url: URL)?, BWError> {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [budgetFileType]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true

        let panelResult = panel.runModal()

        if panelResult != .OK {
            return .success(nil)
        }

        guard let url = panel.url else {
            return .failure(.readingFile())
        }

        do {
            let contents = try String(contentsOf: url, encoding: .utf8)
            return .success((contents, url))
        }
        catch {
            return .failure(.readingFile(underlying: error))
        }
    }

    nonisolated static func saveFile(url: URL, contents: String) -> Result<Void, BWError> {
        BWBudgetFileStore.saveFile(url: url, contents: contents)
    }
}
