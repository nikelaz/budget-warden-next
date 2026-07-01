/*
 * Budget Warden
 * Copyright (c) 2026 Lazarov & Co EOOD
 * Author: Nikola Lazarov
 *
 * Licensed under the Source-Available Educational License.
 * See the LICENSE file in the project root for full terms.
 *
 */

import Foundation

public struct BWBudgetFileState: Sendable, Equatable {
    public let url: URL
    public let modificationDate: Date?
    public let fileSize: Int64?

    public init(
        url: URL,
        modificationDate: Date?,
        fileSize: Int64?
    ) {
        self.url = url.standardizedFileURL
        self.modificationDate = modificationDate
        self.fileSize = fileSize
    }
}

public struct BWBudgetFileSnapshot: Sendable, Equatable {
    public let files: [BWBudgetFileState]

    public init(files: [BWBudgetFileState] = []) {
        var statesByPath: [String: BWBudgetFileState] = [:]

        for file in files {
            statesByPath[file.url.standardizedFileURL.path] = file
        }

        self.files = statesByPath.values.sorted {
            $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending
        }
    }

    public func contains(_ url: URL) -> Bool {
        let standardizedPath = url.standardizedFileURL.path

        return files.contains {
            $0.url.standardizedFileURL.path == standardizedPath
        }
    }
}

public struct BWBudgetRefreshSnapshot: Sendable, Equatable {
    public let vault: BWBudgetFileSnapshot
    public let openFiles: BWBudgetFileSnapshot

    public init(
        vault: BWBudgetFileSnapshot,
        openFiles: BWBudgetFileSnapshot
    ) {
        self.vault = vault
        self.openFiles = openFiles
    }
}
