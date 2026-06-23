import Foundation
import AppleCore

class BWBudgetService {
    @MainActor
    static func createBudget(
        title: String,
        template: BudgetTemplateSelection,
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

        let jsonRes = BWCodec.encodeBudget(budget: budget)

        var json: String = ""

        switch jsonRes {
            case .failure(let error):
                return .failure(.creatingBudget(underlying: error))
            case .success(let resJson):
                json = resJson
        }

        let fileName = BWBudgetFileStore.normalizedFileName(from: title)
        let saveFileRes = await vault.saveNewBudgetInVault(
            fileName: fileName,
            fileExtension: BWBudgetFileStore.budgetFileExtension,
            contents: json
        )

        switch saveFileRes {
            case .failure(let error):
                return .failure(.creatingBudget(underlying: error))
            case .success(let fileUrl):
                budget.url = fileUrl
                return .success(budget)
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
