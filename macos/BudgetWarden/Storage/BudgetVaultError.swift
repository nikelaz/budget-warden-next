import Foundation

enum BudgetVaultError: LocalizedError {
    case vaultNotConfigured
    case vaultUnavailable
    case budgetCreationFailed
    case categoryCreationFailed
    case categorySaveFailed
    case categoryNotFound
    case transactionCreationFailed
    case transactionSaveFailed
    case transactionCategoryNotFound
    case jsonCreationFailed
    case budgetReadFailed(URL)
    case budgetRemoveFailed(URL)

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
        case .categoryNotFound:
            return "Choose an existing category before saving category changes."
        case .transactionCreationFailed:
            return "The transaction data could not be created."
        case .transactionSaveFailed:
            return "The transaction could not be saved."
        case .transactionCategoryNotFound:
            return "Choose an existing category before saving a transaction."
        case .jsonCreationFailed:
            return "The budget JSON could not be created."
        case .budgetReadFailed(let url):
            return "The budget file could not be read: \(url.lastPathComponent)"
        case .budgetRemoveFailed(let url):
            return "The budget file could not be moved to Trash: \(url.lastPathComponent)"
        }
    }
}
