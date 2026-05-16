import Foundation

class BWBudgetService {
    @MainActor
    static func createBudget(
        title: String,
        template: BudgetTemplateSelection,
        vault: BWVault,
        budgetsInVault: [BWBudget]
    ) async -> Result<BWBudget, BWError> {
        var budget: BWBudget

        switch template {
            case .basic:
                budget = BWTemplate.basicBudget(title: title)
                break
            case .blank:
                budget = BWBudget(title: title)
                break
            case .previous(let url):
                if let prevBudget = budgetsInVault.first(where: { $0.url == url }) {
                    budget = prevBudget.cloneAsTemplate(newTitle: title)
                }
                else {
                    return .failure(.findPreviousBudget())
                }
                break
        }

        let jsonRes = BWCodec.encodeBudget(budget: budget)

        var json: String = ""

        switch jsonRes {
            case .failure(let error):
                return .failure(.creatingBudget(underlying: error))
            case .success(let resJson):
                json = resJson
        }

        let fileName = normalizedFileName(from: title)
        let saveFileRes = await vault.saveFileInVault(
            fileName: fileName,
            fileExtension: "budget",
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
