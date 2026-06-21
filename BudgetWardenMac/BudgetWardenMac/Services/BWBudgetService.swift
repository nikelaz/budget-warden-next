import Foundation
import AppleCore

class BWBudgetService {
    @MainActor
    static func createBudget(
        title: String,
        template: BudgetTemplateSelection,
        vault: BWVault,
        budgetsInVault: [BWBudget]
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
        vault: BWVault
    ) async -> Result<Void, BWError> {
        guard let budgetURL = budget.url else {
            return .failure(.saveFailed())
        }

        let jsonRes = BWCodec.encodeBudget(budget: budget)

        let json: String

        switch jsonRes {
            case .failure(let error):
                return .failure(.saveFailed(underlying: error))
            case .success(let resJson):
                json = resJson
        }

        guard BWBudgetFileStore.isBudgetFile(budgetURL) else {
            return .failure(.saveFailed())
        }

        let saveFileRes: Result<Void, BWError>

        if await vault.containsBudgetFile(url: budgetURL) {
            saveFileRes = await vault.saveBudgetFile(
                url: budgetURL,
                contents: json
            )
        }
        else {
            saveFileRes = BWFiles.saveFile(
                url: budgetURL,
                contents: json
            )
        }

        switch saveFileRes {
            case .failure(let error):
                return .failure(.saveFailed(underlying: error))
            case .success:
                return .success(())
        }
    }

}
