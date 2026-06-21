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

enum BWService {
    static func createBudget(
        title: String,
        template: BWTemplateSelection,
        vault: BWVault,
        budgetsInVault: [BWBudget]
    ) async -> Result<BWBudget, BWError> {
        let budget: BWBudget

        switch template {
            case .basic:
                budget = BWTemplate.basicBudget(title: title)
            case .blank:
                budget = BWBudget(title: title)
            case .previous(let url):
                guard let previousBudget = budgetsInVault.first(where: { $0.url == url }) else {
                    return .failure(.findPreviousBudget())
                }

                budget = previousBudget.cloneAsTemplate(newTitle: title)
        }

        let json: String

        switch BWCodec.encodeBudget(budget: budget) {
            case .failure(let error):
                return .failure(.creatingBudget(underlying: error))
            case .success(let resultJSON):
                json = resultJSON
        }

        let saveFileResult = await vault.saveNewBudgetInVault(
            fileName: normalizedFileName(from: title),
            fileExtension: "budget",
            contents: json
        )

        switch saveFileResult {
            case .failure(let error):
                return .failure(.creatingBudget(underlying: error))
            case .success(let fileURL):
                var savedBudget = budget
                savedBudget.url = fileURL
                return .success(savedBudget)
        }
    }

    static func saveBudget(_ budget: BWBudget, vault: BWVault) async -> Result<Void, BWError> {
        guard let budgetURL = budget.url else {
            return .failure(.saveFailed())
        }

        let json: String

        switch BWCodec.encodeBudget(budget: budget) {
            case .failure(let error):
                return .failure(.saveFailed(underlying: error))
            case .success(let resultJSON):
                json = resultJSON
        }

        if await vault.containsBudgetFile(url: budgetURL) {
            return await vault.saveBudgetFile(url: budgetURL, contents: json)
        }

        return BWFiles.saveFile(url: budgetURL, contents: json)
    }

    static func normalizedFileName(from title: String) -> String {
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
}
