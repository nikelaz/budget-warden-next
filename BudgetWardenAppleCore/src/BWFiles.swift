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

public enum BWFiles {
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
}
