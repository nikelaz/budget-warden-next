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
    static func openAndReadFile() -> String? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [budgetFileType]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true

        let panelResult = panel.runModal()

        if panelResult != .OK {
            return nil
        }

        if panel.url == nil {
            return nil
        }

        let url = panel.url!

        return try? String(contentsOf: url, encoding: .utf8)
    }

    static func saveFile(url: URL, json: String) -> Result<Void, BWError> {
        do {
            try json.write(to: url, atomically: true, encoding: .utf8) 
            return .success(())
        }
        catch {
            return .failure(.savingFile)
        }
    }
}
