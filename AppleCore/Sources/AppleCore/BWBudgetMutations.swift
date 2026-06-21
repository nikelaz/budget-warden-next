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

public enum BWBudgetMutation {
    public static func makeBudget(
        title: String,
        template: BWBudgetTemplateSelection,
        budgetsInVault: [BWBudget]
    ) -> Result<BWBudget, BWError> {
        switch template {
            case .basic:
                return .success(BWTemplate.basicBudget(title: title))
            case .blank:
                return .success(BWBudget(title: title))
            case .previous(let url):
                guard let previousBudget = budgetsInVault.first(where: { $0.url == url }) else {
                    return .failure(.findPreviousBudget())
                }

                return .success(previousBudget.cloneAsTemplate(newTitle: title))
        }
    }

    public static func createCategory(
        in budget: BWBudget,
        title: String,
        plannedAmount: UInt64,
        categoryType: BWCategoryType
    ) -> Result<BWBudget, BWError> {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedTitle.isEmpty else {
            return .failure(.validation())
        }

        var budget = budget
        let category = BWCategory(
            ordinal: nextOrdinal(in: budget, for: categoryType),
            title: trimmedTitle,
            amountPlanned: plannedAmount,
            categoryType: categoryType
        )

        budget.categories.append(category)
        return normalizeActualAmounts(in: budget)
    }

    public static func updateBudgetTitle(
        in budget: BWBudget,
        title: String
    ) -> Result<BWBudget, BWError> {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedTitle.isEmpty else {
            return .failure(.validation())
        }

        var budget = budget
        budget.title = trimmedTitle
        return .success(budget)
    }

    public static func updateCategory(
        in budget: BWBudget,
        category updatedCategory: BWCategory
    ) -> Result<BWBudget, BWError> {
        let trimmedTitle = updatedCategory.title.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedTitle.isEmpty else {
            return .failure(.validation())
        }

        var budget = budget

        guard let index = budget.categories.firstIndex(where: { $0.id == updatedCategory.id }) else {
            return .failure(.validation())
        }

        let oldCategoryType = budget.categories[index].categoryType
        var category = updatedCategory
        category.title = trimmedTitle

        if category.categoryType != oldCategoryType {
            category.ordinal = nextOrdinal(
                in: budget,
                for: category.categoryType,
                except: category.id
            )
        }

        budget.categories[index] = category
        normalizeCategoryOrdinals(in: &budget, for: oldCategoryType)
        normalizeCategoryOrdinals(in: &budget, for: category.categoryType)

        return normalizeActualAmounts(in: budget)
    }

    public static func deleteCategory(
        in budget: BWBudget,
        categoryID: UUID
    ) -> Result<BWBudget, BWError> {
        var budget = budget

        guard let index = budget.categories.firstIndex(where: { $0.id == categoryID }) else {
            return .failure(.validation())
        }

        let categoryType = budget.categories[index].categoryType
        budget.categories.remove(at: index)
        normalizeCategoryOrdinals(in: &budget, for: categoryType)

        return normalizeActualAmounts(in: budget)
    }

    public static func createTransaction(
        in budget: BWBudget,
        categoryID: UUID,
        title: String,
        description: String,
        date: Date,
        amount: UInt64
    ) -> Result<BWBudget, BWError> {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDescription = description.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedTitle.isEmpty, amount > 0 else {
            return .failure(.validation())
        }

        var budget = budget

        guard let categoryIndex = budget.categories.firstIndex(where: { $0.id == categoryID }) else {
            return .failure(.validation())
        }

        budget.categories[categoryIndex].transactions.append(BWTransaction(
            title: trimmedTitle,
            description: trimmedDescription,
            date: date,
            amount: amount
        ))

        return normalizeActualAmounts(in: budget)
    }

    public static func updateTransaction(
        in budget: BWBudget,
        transaction: BWTransaction,
        from sourceCategoryID: UUID,
        to destinationCategoryID: UUID
    ) -> Result<BWBudget, BWError> {
        let trimmedTitle = transaction.title.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedTitle.isEmpty, transaction.amount > 0 else {
            return .failure(.validation())
        }

        var budget = budget

        guard let sourceCategoryIndex = budget.categories.firstIndex(where: { $0.id == sourceCategoryID }),
              let destinationCategoryIndex = budget.categories.firstIndex(where: { $0.id == destinationCategoryID }),
              let transactionIndex = budget.categories[sourceCategoryIndex].transactions.firstIndex(where: { $0.id == transaction.id })
        else {
            return .failure(.validation())
        }

        let updatedTransaction = BWTransaction(
            id: transaction.id,
            title: trimmedTitle,
            description: transaction.description.trimmingCharacters(in: .whitespacesAndNewlines),
            date: transaction.date,
            amount: transaction.amount
        )

        if sourceCategoryID == destinationCategoryID {
            budget.categories[sourceCategoryIndex].transactions[transactionIndex] = updatedTransaction
        }
        else {
            budget.categories[sourceCategoryIndex].transactions.remove(at: transactionIndex)
            budget.categories[destinationCategoryIndex].transactions.append(updatedTransaction)
        }

        return normalizeActualAmounts(in: budget)
    }

    public static func deleteTransaction(
        in budget: BWBudget,
        transactionID: UUID,
        from categoryID: UUID
    ) -> Result<BWBudget, BWError> {
        var budget = budget

        guard let categoryIndex = budget.categories.firstIndex(where: { $0.id == categoryID }),
              let transactionIndex = budget.categories[categoryIndex].transactions.firstIndex(where: { $0.id == transactionID })
        else {
            return .failure(.validation())
        }

        budget.categories[categoryIndex].transactions.remove(at: transactionIndex)
        return normalizeActualAmounts(in: budget)
    }

    public static func canMoveCategory(
        _ category: BWCategory,
        in budget: BWBudget,
        by offset: Int
    ) -> Bool {
        guard abs(offset) == 1 else {
            return false
        }

        let categories = orderedCategoryIndexes(in: budget, for: category.categoryType)

        guard let index = categories.firstIndex(where: { $0.category.id == category.id }) else {
            return false
        }

        let targetIndex = index + offset
        return targetIndex >= 0 && targetIndex < categories.count
    }

    public static func moveCategory(
        _ category: BWCategory,
        in budget: BWBudget,
        by offset: Int
    ) -> Result<BWBudget, BWError> {
        guard abs(offset) == 1 else {
            return .failure(.validation())
        }

        var budget = budget
        var categories = orderedCategoryIndexes(in: budget, for: category.categoryType)

        guard let index = categories.firstIndex(where: { $0.category.id == category.id }) else {
            return .failure(.validation())
        }

        let targetIndex = index + offset

        guard targetIndex >= 0 && targetIndex < categories.count else {
            return .failure(.validation())
        }

        categories.swapAt(index, targetIndex)

        for (ordinal, categoryIndex) in categories.map(\.index).enumerated() {
            budget.categories[categoryIndex].ordinal = ordinal
        }

        return normalizeActualAmounts(in: budget)
    }

    public static func orderedCategories(
        in budget: BWBudget,
        for categoryType: BWCategoryType? = nil
    ) -> [BWCategory] {
        budget.categories.enumerated()
            .filter { _, category in
                categoryType.map { category.categoryType == $0 } ?? true
            }
            .sorted { lhs, rhs in
                if lhs.element.categoryType != rhs.element.categoryType {
                    return lhs.element.categoryType.rawValue < rhs.element.categoryType.rawValue
                }

                if lhs.element.ordinal == rhs.element.ordinal {
                    return lhs.offset < rhs.offset
                }

                return lhs.element.ordinal < rhs.element.ordinal
            }
            .map(\.element)
    }

    public static func nextOrdinal(
        in budget: BWBudget,
        for categoryType: BWCategoryType,
        except categoryID: UUID? = nil
    ) -> Int {
        let maxOrdinal = budget.categories
            .filter { category in
                category.categoryType == categoryType && category.id != categoryID
            }
            .map(\.ordinal)
            .max()

        return (maxOrdinal ?? -1) + 1
    }

    public static func normalizeCategoryOrdinals(
        in budget: inout BWBudget,
        for categoryType: BWCategoryType
    ) {
        let categories = orderedCategoryIndexes(in: budget, for: categoryType)

        for (ordinal, categoryIndex) in categories.map(\.index).enumerated() {
            budget.categories[categoryIndex].ordinal = ordinal
        }
    }

    public static func normalizeActualAmounts(in budget: BWBudget) -> Result<BWBudget, BWError> {
        var budget = budget

        guard BWCodec.normalizeActualAmounts(in: &budget) else {
            return .failure(.amountOverflow)
        }

        return .success(budget)
    }

    private static func orderedCategoryIndexes(
        in budget: BWBudget,
        for categoryType: BWCategoryType
    ) -> [(index: Int, category: BWCategory)] {
        budget.categories.enumerated()
            .filter { $0.element.categoryType == categoryType }
            .sorted { lhs, rhs in
                if lhs.element.ordinal == rhs.element.ordinal {
                    return lhs.offset < rhs.offset
                }

                return lhs.element.ordinal < rhs.element.ordinal
            }
            .map { (index: $0.offset, category: $0.element) }
    }
}
