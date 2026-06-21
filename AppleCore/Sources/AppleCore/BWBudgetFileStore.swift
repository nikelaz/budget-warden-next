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
}
