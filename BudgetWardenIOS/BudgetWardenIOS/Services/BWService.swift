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

        switch BWBudgetMutation.makeBudget(
            title: title,
            template: template,
            budgetsInVault: budgetsInVault
        ) {
            case .failure(let error):
                return .failure(error)
            case .success(let result):
                budget = result
        }

        let json: String

        switch BWCodec.encodeBudget(budget: budget) {
            case .failure(let error):
                return .failure(.creatingBudget(underlying: error))
            case .success(let resultJSON):
                json = resultJSON
        }

        let saveFileResult = await vault.saveNewBudgetInVault(
            fileName: BWBudgetFileStore.normalizedFileName(from: title),
            fileExtension: BWBudgetFileStore.budgetFileExtension,
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

        guard BWBudgetFileStore.isBudgetFile(budgetURL) else {
            return .failure(.saveFailed())
        }

        if await vault.containsBudgetFile(url: budgetURL) {
            return await vault.saveBudgetFile(url: budgetURL, contents: json)
        }

        return BWFiles.saveFile(url: budgetURL, contents: json)
    }
}
