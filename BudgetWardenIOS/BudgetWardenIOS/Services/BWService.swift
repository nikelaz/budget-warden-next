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
        budgetsInVault: [BWBudget],
        deviceID: String
    ) async -> Result<BWBudget, BWError> {
        var budget: BWBudget

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

        budget = budget.withNewRevision(modifiedByDeviceID: deviceID)

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

    static func saveBudget(
        _ budget: BWBudget,
        baseBudget: BWBudget?,
        vault: BWVault,
        deviceID: String
    ) async -> Result<BWBudgetSaveOutcome, BWError> {
        guard let budgetURL = budget.url else {
            return .failure(.saveFailed())
        }

        guard BWBudgetFileStore.isBudgetFile(budgetURL) else {
            return .failure(.saveFailed())
        }

        if await vault.containsBudgetFile(url: budgetURL) {
            return await vault.saveBudgetFile(
                budget,
                baseBudget: baseBudget,
                deviceID: deviceID
            )
        }

        return BWBudgetFileStore.saveBudget(
            budget,
            baseBudget: baseBudget,
            to: budgetURL,
            modifiedByDeviceID: deviceID
        )
    }
}
