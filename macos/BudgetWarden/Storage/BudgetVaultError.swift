import Foundation

enum BudgetVaultError: LocalizedError {
    case vaultNotConfigured
    case vaultUnavailable
    case budgetCreationFailed
    case categoryCreationFailed
    case categorySaveFailed
    case jsonCreationFailed
    case budgetReadFailed(URL)

    var errorDescription: Swift.String? {
        switch self {
        case .vaultNotConfigured:
            return "Choose a budget vault before saving budgets."
        case .vaultUnavailable:
            return "The budget vault could not be found. Choose a vault folder again."
        case .budgetCreationFailed:
            return "The budget data could not be created."
        case .categoryCreationFailed:
            return "The category data could not be created."
        case .categorySaveFailed:
            return "The category could not be saved."
        case .jsonCreationFailed:
            return "The budget JSON could not be created."
        case .budgetReadFailed(let url):
            return "The budget file could not be read: \(url.lastPathComponent)"
        }
    }
}
