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

private let budgetFileType = UTType(filenameExtension: "budget") ?? .data

class BWFiles {
    static func openAndReadFile() -> (contents: String, url: URL)? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [budgetFileType]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true

        let panelResult = panel.runModal()

        if panelResult != .OK {
            return nil
        }

        guard let url = panel.url else {
            return nil
        }

        guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }

        return (contents, url)
    }

    nonisolated static func saveFile(url: URL, contents: String) -> Result<Void, BWError> {
        do {
            try contents.write(to: url, atomically: true, encoding: .utf8)
            return .success(())
        }
        catch {
            return .failure(.savingFile(underlying: error))
        }
    }
}
