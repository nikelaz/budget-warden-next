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

public struct BWBudgetDirectoryReadResult: Sendable {
    public var budgets: [BWBudget]
    public var skippedFiles: [String]

    public init(budgets: [BWBudget], skippedFiles: [String]) {
        self.budgets = budgets
        self.skippedFiles = skippedFiles
    }
}

public enum BWBudgetFileStore {
    public static let budgetFileExtension = "budget"

    public static func normalizedFileName(from title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)

        let invalidCharacters = CharacterSet(charactersIn: "/\\?%*|\"<>:")
            .union(.newlines)
            .union(.controlCharacters)

        let cleaned = trimmed
            .components(separatedBy: invalidCharacters)
            .joined(separator: "-")
            .replacingOccurrences(
                of: #"\s+"#,
                with: " ",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return cleaned.isEmpty ? "Untitled Budget" : cleaned
    }

    public static func isBudgetFile(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == budgetFileExtension
    }

    public static func isBudgetFile(_ fileURL: URL, in directoryURL: URL) -> Bool {
        let directoryURL = directoryURL.standardizedFileURL
        let fileURL = fileURL.standardizedFileURL

        return isBudgetFile(fileURL)
            && fileURL.deletingLastPathComponent() == directoryURL
    }

    public static func saveFile(url: URL, contents: String) -> Result<Void, BWError> {
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

    public static func readBudgetFile(url: URL) -> Result<BWBudget, BWError> {
        coordinatedRead(url: url) { coordinatedURL in
            do {
                let json = try String(contentsOf: coordinatedURL, encoding: .utf8)
                return BWCodec.decodeBudget(json: json, url: url)
            }
            catch {
                return .failure(.readingFile(underlying: error))
            }
        }
    }

    public static func saveBudget(
        _ budget: BWBudget,
        baseBudget: BWBudget?,
        to url: URL,
        modifiedByDeviceID: String
    ) -> Result<BWBudgetSaveOutcome, BWError> {
        coordinatedWrite(url: url) { coordinatedURL in
            let latestBudget: BWBudget

            switch readBudgetFileUncoordinated(url: coordinatedURL, originalURL: url) {
                case .failure(let error):
                    return .failure(.saveFailed(underlying: error))
                case .success(let budget):
                    latestBudget = budget
            }

            let baseBudget = baseBudget ?? budget
            let budgetToSave: BWBudget

            if latestBudget.revisionID == baseBudget.revisionID {
                budgetToSave = budget
            }
            else {
                switch BWBudgetMerge.merge(
                    base: baseBudget,
                    local: budget,
                    latest: latestBudget
                ) {
                    case .conflict(let item):
                        return .success(.conflict(BWBudgetSaveConflict(
                            fileURL: url,
                            baseBudget: baseBudget,
                            localBudget: budget,
                            latestBudget: latestBudget,
                            item: item
                        )))
                    case .merged(let mergedBudget):
                        budgetToSave = mergedBudget
                }
            }

            return writeBudgetFileUncoordinated(
                budgetToSave,
                to: coordinatedURL,
                originalURL: url,
                modifiedByDeviceID: modifiedByDeviceID
            )
        }
    }

    public static func resolveSaveConflict(
        _ conflict: BWBudgetSaveConflict,
        choice: BWBudgetConflictChoice,
        modifiedByDeviceID: String
    ) -> Result<BWBudgetSaveOutcome, BWError> {
        coordinatedWrite(url: conflict.fileURL) { coordinatedURL in
            let latestBudget: BWBudget

            switch readBudgetFileUncoordinated(url: coordinatedURL, originalURL: conflict.fileURL) {
                case .failure(let error):
                    return .failure(.saveFailed(underlying: error))
                case .success(let budget):
                    latestBudget = budget
            }

            switch BWBudgetMerge.merge(
                base: conflict.baseBudget,
                local: conflict.localBudget,
                latest: latestBudget,
                resolution: BWBudgetMergeResolution(
                    key: conflict.item.key,
                    choice: choice
                )
            ) {
                case .conflict(let item):
                    return .success(.conflict(BWBudgetSaveConflict(
                        fileURL: conflict.fileURL,
                        baseBudget: conflict.baseBudget,
                        localBudget: conflict.localBudget,
                        latestBudget: latestBudget,
                        item: item
                    )))
                case .merged(let resolvedBudget):
                    return writeBudgetFileUncoordinated(
                        resolvedBudget,
                        to: coordinatedURL,
                        originalURL: conflict.fileURL,
                        modifiedByDeviceID: modifiedByDeviceID
                    )
            }
        }
    }

    public static func makeUniqueVaultFileURL(
        directoryURL: URL,
        fileName: String,
        fileExtension: String = budgetFileExtension
    ) -> URL {
        var candidateURL = directoryURL
            .appendingPathComponent(fileName)
            .appendingPathExtension(fileExtension)

        var index = 2

        while FileManager.default.fileExists(atPath: candidateURL.path) {
            candidateURL = directoryURL
                .appendingPathComponent("\(fileName) \(index)")
                .appendingPathExtension(fileExtension)

            index += 1
        }

        return candidateURL
    }

    public static func readBudgetsFromDirectory(
        url: URL,
        sortedByTitle: Bool = true
    ) -> Result<BWBudgetDirectoryReadResult, BWError> {
        let didStartAccessing = url.startAccessingSecurityScopedResource()

        defer {
            if didStartAccessing {
                url.stopAccessingSecurityScopedResource()
            }
        }

        do {
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: true
            )

            let files = try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: nil
            )

            var budgets: [BWBudget] = []
            var skippedFiles: [String] = []

            for file in files where isBudgetFile(file) {
                guard let json = try? String(contentsOf: file, encoding: .utf8) else {
                    skippedFiles.append(file.lastPathComponent)
                    continue
                }

                switch BWCodec.decodeBudget(json: json, url: file) {
                    case .success(let budget):
                        budgets.append(budget)
                    case .failure:
                        skippedFiles.append(file.lastPathComponent)
                }
            }

            if sortedByTitle {
                budgets.sort {
                    $0.title.localizedStandardCompare($1.title) == .orderedAscending
                }
            }

            return .success(BWBudgetDirectoryReadResult(
                budgets: budgets,
                skippedFiles: skippedFiles
            ))
        }
        catch {
            return .failure(.vaultNotSet(underlying: error))
        }
    }

    private static func coordinatedRead<Value>(
        url: URL,
        read: (URL) -> Result<Value, BWError>
    ) -> Result<Value, BWError> {
        let didStartAccessing = url.startAccessingSecurityScopedResource()

        defer {
            if didStartAccessing {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var result: Result<Value, BWError> = .failure(.readingFile())

        coordinator.coordinate(
            readingItemAt: url,
            options: [],
            error: &coordinationError
        ) { coordinatedURL in
            result = read(coordinatedURL)
        }

        if let coordinationError {
            return .failure(.readingFile(underlying: coordinationError))
        }

        return result
    }

    private static func coordinatedWrite<Value>(
        url: URL,
        write: (URL) -> Result<Value, BWError>
    ) -> Result<Value, BWError> {
        let didStartAccessing = url.startAccessingSecurityScopedResource()

        defer {
            if didStartAccessing {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var result: Result<Value, BWError> = .failure(.saveFailed())

        coordinator.coordinate(
            writingItemAt: url,
            options: [],
            error: &coordinationError
        ) { coordinatedURL in
            result = write(coordinatedURL)
        }

        if let coordinationError {
            return .failure(.saveFailed(underlying: coordinationError))
        }

        return result
    }

    private static func readBudgetFileUncoordinated(
        url: URL,
        originalURL: URL
    ) -> Result<BWBudget, BWError> {
        do {
            let json = try String(contentsOf: url, encoding: .utf8)
            return BWCodec.decodeBudget(json: json, url: originalURL)
        }
        catch {
            return .failure(.readingFile(underlying: error))
        }
    }

    private static func writeBudgetFileUncoordinated(
        _ budget: BWBudget,
        to url: URL,
        originalURL: URL,
        modifiedByDeviceID: String
    ) -> Result<BWBudgetSaveOutcome, BWError> {
        var budgetToSave = budget.withNewRevision(modifiedByDeviceID: modifiedByDeviceID)
        budgetToSave.url = originalURL

        guard BWCodec.normalizeActualAmounts(in: &budgetToSave) else {
            return .failure(.amountOverflow)
        }

        let json: String

        switch BWCodec.encodeBudget(budget: budgetToSave) {
            case .failure(let error):
                return .failure(.saveFailed(underlying: error))
            case .success(let resultJSON):
                json = resultJSON
        }

        do {
            try json.write(to: url, atomically: true, encoding: .utf8)
            return .success(.saved(budgetToSave))
        }
        catch {
            return .failure(.saveFailed(underlying: error))
        }
    }
}
