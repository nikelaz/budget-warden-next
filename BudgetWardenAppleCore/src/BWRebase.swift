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

public enum BWRebaseOperations {
    case BudgetCreate
    case BudgetUpdate
    case CategoryCreate
    case CategoryUpdate(categoryId: UUID)
    case CategoryDelete(categoryId: UUID)
    case TransactionCreate(categoryId: UUID, transactionId: UUID)
    case TransactionUpdate(categoryId: UUID, transactionId: UUID)
    case TransactionDelete(categoryId: UUID, transactionId: UUID)
}

public enum BWRebase {
    static func rebase(budgetInMemory: BWBudget, operation: BWRebaseOperations) -> Result<BWBudget, BWError> {
        guard let budgetURL = budgetInMemory.url else {
            return .failure(.rebaseFailed())
        }

        let budgetOnDisk: BWBudget
        let readBudgetRes: Result<BWBudget, BWError>

        readBudgetRes = BWFiles.readBudgetFile(url: budgetURL)

        switch readBudgetRes {
            case .failure(let error):
                return .failure(.rebaseFailed(underlying: error))
            case .success(let budget):
                budgetOnDisk = budget
        }

        if budgetInMemory.revision == budgetOnDisk.revision {
            // exit case one - budgets are identical
            return .success(budgetInMemory)
        }

        print("Budget are NOT identical")

        switch operation {
            case .BudgetCreate, .BudgetUpdate, .CategoryCreate:
                return .success(budgetInMemory)
            case .CategoryUpdate(let categoryId):
                if budgetOnDisk.categories.contains(where: { $0.id == categoryId }) {
                    // @TODO: We have to apply changes here
                    return .success(budgetOnDisk)
                }
                else {
                    // @TODO: More specific error messages for cases like this one
                    return .failure(.rebaseFailed())
                }
            case .CategoryDelete:
                return .success(budgetInMemory)
            case .TransactionCreate:
                return .success(budgetInMemory)
            case .TransactionUpdate:
                return .success(budgetInMemory)
            case .TransactionDelete:
                return .success(budgetInMemory)
        }
    }
}
