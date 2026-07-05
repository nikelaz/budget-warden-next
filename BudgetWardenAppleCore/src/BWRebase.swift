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

public enum BWRebaseOperation {
    case BudgetCreate
    case BudgetUpdate
    case CategoryCreate(categoryId: UUID)
    case CategoryUpdate(categoryId: UUID)
    case CategoryDelete(categoryId: UUID)
    case CategoriesBulkOrdinalUpdate(categoryIds: [UUID])
    case TransactionCreate(categoryId: UUID, transactionId: UUID)
    case TransactionUpdate(sourceCategoryId: UUID, destinationCategoryId: UUID, transactionId: UUID)
    case TransactionDelete(categoryId: UUID, transactionId: UUID)
    case Other
}

public enum BWRebase {
    static func rebase(budgetInMemory: BWBudget, operation: BWRebaseOperation) -> Result<BWBudget, BWError> {
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

        switch operation {
            case .BudgetCreate:
                return .success(budgetInMemory)
            case .BudgetUpdate:
                var rebasedBudget = budgetOnDisk
                rebasedBudget.title = budgetInMemory.title

                return .success(rebasedBudget)
            case .CategoryCreate(let categoryId):
                var rebasedBudget = budgetOnDisk

                guard var newCategory = budgetInMemory.categories.first(where: { $0.id == categoryId }) else {
                    return .failure(.rebaseFailed())
                }

                let maxOrdinal = rebasedBudget.categories
                    .filter { $0.categoryType == newCategory.categoryType }
                    .map(\.ordinal)
                    .max()

                newCategory.ordinal = (maxOrdinal ?? -1) + 1
                rebasedBudget.categories.append(newCategory)

                return .success(rebasedBudget)
            case .CategoryUpdate(let categoryId):
                var rebasedBudget = budgetOnDisk

                let categoryIndex = rebasedBudget.categories.firstIndex(where: { $0.id == categoryId })

                guard let updatedCategory = budgetInMemory.categories.first(where: { $0.id == categoryId }) else {
                    return .failure(.rebaseFailed())
                }

                if categoryIndex == nil {
                    rebasedBudget.categories.append(updatedCategory)
                    return .success(rebasedBudget)
                }
                
                var rebasedCategory = rebasedBudget.categories[categoryIndex!]
                
                // @TODO: More sophisticated/granular logic here
                // The granularity here means that a hypothetical change could be overriden
                // because if the conflict is within the category we update all fields with last one wins
                rebasedCategory.title = updatedCategory.title
                rebasedCategory.amountPlanned = updatedCategory.amountPlanned
                rebasedCategory.amountAccumulated = updatedCategory.amountAccumulated
                rebasedCategory.categoryType = updatedCategory.categoryType
                rebasedCategory.ordinal = updatedCategory.ordinal
                
                rebasedBudget.categories[categoryIndex!] = updatedCategory

                return .success(rebasedBudget)
            case .CategoryDelete(let categoryId):
                var rebasedBudget = budgetOnDisk

                guard let categoryIndex = rebasedBudget.categories.firstIndex(where: { $0.id == categoryId }) else {
                    return .success(rebasedBudget)
                }

                rebasedBudget.categories.remove(at: categoryIndex)

                return .success(rebasedBudget)
            case .TransactionCreate(let categoryId, let transactionId):
                var rebasedBudget = budgetOnDisk

                guard let categoryInMemory = budgetInMemory.categories.first(where: { $0.id == categoryId }) else {
                    return .failure(.rebaseFailed())
                }

                var categoryIndex = rebasedBudget.categories.firstIndex(where: { $0.id == categoryId })

                if categoryIndex == nil {
                    rebasedBudget.categories.append(categoryInMemory)
                    categoryIndex = rebasedBudget.categories.firstIndex(where: { $0.id == categoryId })
                }

                guard let categoryIndex else {
                    return .failure(.rebaseFailed())
                }

                guard let newTransaction = categoryInMemory.transactions.first(where: { $0.id == transactionId }) else {
                    return .failure(.rebaseFailed())
                }

                if rebasedBudget.categories[categoryIndex].transactions.contains(where: { $0.id == transactionId }) {
                    return .success(rebasedBudget)
                }

                rebasedBudget.categories[categoryIndex].transactions.append(newTransaction)

                return .success(rebasedBudget)
            case .TransactionUpdate(let sourceCategoryId, let destinationCategoryId, let transactionId):
                var rebasedBudget = budgetOnDisk

                guard let sourceCategoryIndex = rebasedBudget.categories.firstIndex(where: { $0.id == sourceCategoryId }) else {
                    return .failure(.rebaseFailed())
                }

                guard let destinationCategoryIndex = rebasedBudget.categories.firstIndex(where: { $0.id == destinationCategoryId }) else {
                    return .failure(.rebaseFailed())
                }

                guard let destinationCategoryInMemory = budgetInMemory.categories.first(where: { $0.id == destinationCategoryId }) else {
                    return .failure(.rebaseFailed())
                }

                guard let transactionIndex = rebasedBudget.categories[sourceCategoryIndex].transactions.firstIndex(where: { $0.id == transactionId }) else {
                    return .failure(.rebaseFailed())
                }

                guard let updatedTransaction = destinationCategoryInMemory.transactions.first(where: { $0.id == transactionId }) else {
                    return .failure(.rebaseFailed())
                }

                if sourceCategoryId == destinationCategoryId {
                    rebasedBudget.categories[sourceCategoryIndex].transactions[transactionIndex] = updatedTransaction
                }
                else {
                    rebasedBudget.categories[sourceCategoryIndex].transactions.remove(at: transactionIndex)
                    rebasedBudget.categories[destinationCategoryIndex].transactions.append(updatedTransaction)
                }

                return .success(rebasedBudget)
            case .TransactionDelete(let categoryId, let transactionId):
                var rebasedBudget = budgetOnDisk

                guard let categoryIndex = rebasedBudget.categories.firstIndex(where: { $0.id == categoryId }) else {
                    return .failure(.rebaseFailed())
                }

                guard let transactionIndex = rebasedBudget.categories[categoryIndex].transactions.firstIndex(where: { $0.id == transactionId }) else {
                    guard let movedCategoryIndex = rebasedBudget.categories.firstIndex(where: { category in
                        category.transactions.contains(where: { $0.id == transactionId })
                    }) else {
                        return .failure(.rebaseFailed())
                    }

                    rebasedBudget.categories[movedCategoryIndex].transactions.removeAll(where: { $0.id == transactionId })
                    return .success(rebasedBudget)
                }

                rebasedBudget.categories[categoryIndex].transactions.remove(at: transactionIndex)

                return .success(rebasedBudget)
            case .CategoriesBulkOrdinalUpdate(let categoryIds):
                var rebasedBudget = budgetOnDisk

                for categoryId in categoryIds {
                    guard let categoryIndex = rebasedBudget.categories.firstIndex(where: { $0.id == categoryId }) else {
                        continue
                    }

                    guard let updatedCategory = budgetInMemory.categories.first(where: { $0.id == categoryId }) else {
                        continue
                    }

                    rebasedBudget.categories[categoryIndex].ordinal = updatedCategory.ordinal
                }

                return .success(rebasedBudget)
            case .Other:
                return .failure(.rebaseFailed())
        }
    }
}
