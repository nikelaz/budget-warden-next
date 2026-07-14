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

public struct BWBudgetDirectoryReadResult: Sendable {
    public var budgets: [BWBudget]
    public var skippedFiles: [String]

    public init(budgets: [BWBudget], skippedFiles: [String]) {
        self.budgets = budgets
        self.skippedFiles = skippedFiles
    }
}

public struct BWBudgetOpenResult: Sendable {
    public var budget: BWBudget
    public var vaultReadResult: BWBudgetDirectoryReadResult?

    public init(
        budget: BWBudget,
        vaultReadResult: BWBudgetDirectoryReadResult? = nil
    ) {
        self.budget = budget
        self.vaultReadResult = vaultReadResult
    }
}

public enum BWBudgetService {
    public static func refreshSnapshot(
        for budgets: [BWBudget],
        vault: BWVault
    ) async -> Result<BWBudgetRefreshSnapshot, BWError> {
        switch await vault.budgetFileSnapshot() {
            case .failure(let error):
                return .failure(error)
            case .success(let vaultSnapshot):
                let externalURLs = externalBudgetURLs(
                    in: budgets,
                    vaultSnapshot: vaultSnapshot
                )
                var files = vaultSnapshot.files

                for url in externalURLs {
                    switch BWFiles.budgetFileState(url: url) {
                        case .success(let state):
                            files.append(state)
                        case .failure:
                            continue
                    }
                }

                return .success(BWBudgetRefreshSnapshot(
                    vault: vaultSnapshot,
                    openFiles: BWBudgetFileSnapshot(files: files)
                ))
        }
    }

    public static func externalBudgetURLs(
        in budgets: [BWBudget],
        vaultSnapshot: BWBudgetFileSnapshot
    ) -> [URL] {
        var urls: [URL] = []
        var seenPaths: Set<String> = []

        for budget in budgets {
            guard let url = budget.url?.standardizedFileURL,
                  !vaultSnapshot.contains(url)
            else {
                continue
            }

            guard !seenPaths.contains(url.path) else {
                continue
            }

            urls.append(url)
            seenPaths.insert(url.path)
        }

        return urls
    }

    public static func loadBudgets(
        vault: BWVault
    ) async -> Result<BWBudgetDirectoryReadResult, BWError> {
        switch await vault.readBudgetsFromVault() {
            case .failure(let error):
                return .failure(error)
            case .success(let result):
                return .success(normalizeDirectoryReadResult(result))
        }
    }

    public static func openBudget(
        at url: URL,
        vault: BWVault
    ) async -> Result<BWBudgetOpenResult, BWError> {
        guard BWFiles.isBudgetFile(url) else {
            return .failure(.invalidBudgetFile(message: "This is not a Budget Warden budget file."))
        }

        if await vault.containsBudgetFile(url: url) {
            switch await loadBudgets(vault: vault) {
                case .failure(let error):
                    return .failure(error)
                case .success(let result):
                    if let budget = result.budgets.first(where: {
                        $0.url?.standardizedFileURL == url.standardizedFileURL
                    }) {
                        return .success(BWBudgetOpenResult(
                            budget: budget,
                            vaultReadResult: result
                        ))
                    }
            }
        }

        switch BWFiles.readBudgetFile(url: url) {
            case .failure(let error):
                return .failure(error)
            case .success(let budget):
                switch normalizeActualAmounts(in: budget) {
                    case .failure(let error):
                        return .failure(error)
                    case .success(let budget):
                        return .success(BWBudgetOpenResult(budget: budget))
                }
        }
    }

    public static func createBudget(
        title: String,
        template: BWTemplateSelection,
        budgetsInVault: [BWBudget],
        vault: BWVault
    ) async -> Result<BWBudget, BWError> {
        let draftBudget: BWBudget

        switch template {
            case .basic:
                draftBudget = BWTemplate.basicBudget(title: title)
            case .blank:
                draftBudget = BWBudget(title: title)
            case .previous(let url):
                guard let previousBudget = budgetsInVault.first(where: { $0.url == url }) else {
                    return .failure(.findPreviousBudget())
                }

                draftBudget = previousBudget.cloneAsTemplate(newTitle: title)
        }

        let budgetToSave = await BWCRDT.prepareNew(draftBudget)

        let json: String

        switch BWCodec.encodeBudget(budget: budgetToSave) {
            case .failure(let error):
                return .failure(.creatingBudget(underlying: error))
            case .success(let result):
                json = result
        }

        let fileName = BWFiles.normalizedFileName(from: title)
        let saveFileResult = await vault.saveNewBudgetInVault(
            fileName: fileName,
            fileExtension: BWFiles.budgetFileExtension,
            contents: json
        )

        switch saveFileResult {
            case .failure(let error):
                return .failure(.creatingBudget(underlying: error))
            case .success(let fileURL):
                var savedBudget = budgetToSave
                savedBudget.url = fileURL
                return .success(savedBudget)
        }
    }

    public static func deleteBudget(
        _ budget: BWBudget,
        vault: BWVault
    ) async -> Result<Void, BWError> {
        guard let url = budget.url else {
            return .success(())
        }

        guard BWFiles.isBudgetFile(url) else {
            return .failure(.budgetRemove())
        }

        return await vault.removeBudgetFromVault(url: url)
    }

    public static func saveBudget(
        _ budget: BWBudget,
        vault: BWVault,
        operation: BWRebaseOperation
    ) async -> Result<BWBudget, BWError> {
        guard let budgetURL = budget.url else {
            return .failure(.saveFailed())
        }

        var normalizedBudget: BWBudget

        switch normalizeActualAmounts(in: budget) {
            case .failure(let error):
                return .failure(error)
            case .success(let budget):
                normalizedBudget = budget
        }

        if case .CategoriesBulkOrdinalUpdate = operation {
            let budgetOnDisk: BWBudget
            switch await vault.readBudgetFile(url: budgetURL) {
                case .failure(let error):
                    return .failure(.saveFailed(underlying: error))
                case .success(let budget):
                    budgetOnDisk = budget
            }

            switch BWRebase.rebase(
                budgetInMemory: normalizedBudget,
                onto: budgetOnDisk,
                operation: operation
            ) {
                case .failure(let error):
                    return .failure(.saveFailed(underlying: error))
                case .success(let budget):
                    normalizedBudget = budget
            }

            switch normalizeActualAmounts(in: normalizedBudget) {
                case .failure(let error):
                    return .failure(error)
                case .success(let budget):
                    normalizedBudget = budget
            }
        }

        let originalBudget = BWCRDT.materialize(normalizedBudget)

        normalizedBudget = await BWCRDT.applyingChanges(
            from: originalBudget,
            to: normalizedBudget
        )
        normalizedBudget.url = budgetURL

        guard BWFiles.isBudgetFile(budgetURL) else {
            return .failure(.saveFailed())
        }

        switch await vault.mergeAndSaveBudgetFile(url: budgetURL, incoming: normalizedBudget) {
            case .failure(let error):
                return .failure(.saveFailed(underlying: error))
            case .success(let saved):
                return .success(saved)
        }
    }

    public static func createCategory(
        in budget: BWBudget,
        title: String,
        plannedAmount: UInt64,
        categoryType: BWCategoryType,
        vault: BWVault
    ) async -> Result<BWBudget, BWError> {
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

        switch normalizeActualAmounts(in: budget) {
            case .failure(let error):
                return .failure(error)
            case .success(let budget):
                return await saveBudget(budget, vault: vault, operation: .CategoryCreate(categoryId: category.id))
        }
    }

    public static func updateBudgetTitle(
        in budget: BWBudget,
        title: String,
        vault: BWVault
    ) async -> Result<BWBudget, BWError> {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedTitle.isEmpty else {
            return .failure(.validation())
        }

        var budget = budget
        budget.title = trimmedTitle
        return await saveBudget(budget, vault: vault, operation: .BudgetUpdate)
    }

    public static func updateCategory(
        in budget: BWBudget,
        category: BWCategory,
        vault: BWVault
    ) async -> Result<BWBudget, BWError> {
        let trimmedTitle = category.title.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedTitle.isEmpty else {
            return .failure(.validation())
        }

        var budget = budget

        guard let index = budget.categories.firstIndex(where: { $0.id == category.id }) else {
            return .failure(.validation())
        }

        let oldCategoryType = budget.categories[index].categoryType
        var category = category

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

        switch normalizeActualAmounts(in: budget) {
            case .failure(let error):
                return .failure(error)
            case .success(let budget):
                return await saveBudget(budget, vault: vault, operation: .CategoryUpdate(categoryId: category.id))
        }
    }

    public static func deleteCategory(
        in budget: BWBudget,
        categoryID: UUID,
        vault: BWVault
    ) async -> Result<BWBudget, BWError> {
        var budget = budget

        guard let index = budget.categories.firstIndex(where: { $0.id == categoryID }) else {
            return .failure(.validation())
        }

        let categoryType = budget.categories[index].categoryType
        budget.categories.remove(at: index)
        normalizeCategoryOrdinals(in: &budget, for: categoryType)

        switch normalizeActualAmounts(in: budget) {
            case .failure(let error):
                return .failure(error)
            case .success(let budget):
                return await saveBudget(budget, vault: vault, operation: .CategoryDelete(categoryId: categoryID))
        }
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
        by offset: Int,
        vault: BWVault
    ) async -> Result<BWBudget, BWError> {
        switch prepareCategoryMove(category, in: budget, by: offset) {
            case .failure(let error):
                return .failure(error)
            case .success(let budget):
                let reorderedCategoryIDs = budget.categories
                    .filter { $0.categoryType == category.categoryType }
                    .map(\.id)
                return await saveBudget(
                    budget,
                    vault: vault,
                    operation: .CategoriesBulkOrdinalUpdate(categoryIds: reorderedCategoryIDs)
                )
        }
    }

    public static func prepareCategoryMove(
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

        return .success(budget)
    }

    public static func moveCategories(
        in budget: BWBudget,
        for categoryType: BWCategoryType,
        fromOffsets sourceOffsets: IndexSet,
        toOffset destination: Int,
        vault: BWVault
    ) async -> Result<BWBudget, BWError> {
        switch prepareCategoryMove(
            in: budget,
            for: categoryType,
            fromOffsets: sourceOffsets,
            toOffset: destination
        ) {
            case .failure(let error):
                return .failure(error)
            case .success(let budget):
                let reorderedCategoryIDs = budget.categories
                    .filter { $0.categoryType == categoryType }
                    .map(\.id)
                return await saveBudget(
                    budget,
                    vault: vault,
                    operation: .CategoriesBulkOrdinalUpdate(categoryIds: reorderedCategoryIDs)
                )
        }
    }

    public static func prepareCategoryMove(
        in budget: BWBudget,
        for categoryType: BWCategoryType,
        fromOffsets sourceOffsets: IndexSet,
        toOffset destination: Int
    ) -> Result<BWBudget, BWError> {
        guard !sourceOffsets.isEmpty else {
            return .success(budget)
        }

        var budget = budget
        let categories = orderedCategoryIndexes(in: budget, for: categoryType)

        guard sourceOffsets.allSatisfy({ categories.indices.contains($0) }),
              (0...categories.count).contains(destination)
        else {
            return .failure(.validation())
        }

        let sortedSourceOffsets = sourceOffsets.sorted()
        let movedCategories = sortedSourceOffsets.map { categories[$0] }
        var remainingCategories = categories.enumerated()
            .filter { !sourceOffsets.contains($0.offset) }
            .map(\.element)

        let adjustedDestination = destination - sortedSourceOffsets.filter { $0 < destination }.count

        guard (0...remainingCategories.count).contains(adjustedDestination) else {
            return .failure(.validation())
        }

        remainingCategories.insert(contentsOf: movedCategories, at: adjustedDestination)

        for (ordinal, categoryIndex) in remainingCategories.map(\.index).enumerated() {
            budget.categories[categoryIndex].ordinal = ordinal
        }

        return .success(budget)
    }

    public static func createTransaction(
        in budget: BWBudget,
        categoryID: UUID,
        title: String,
        description: String,
        date: Date,
        amount: UInt64,
        vault: BWVault
    ) async -> Result<BWBudget, BWError> {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDescription = description.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedTitle.isEmpty, amount > 0 else {
            return .failure(.validation())
        }

        var budget = budget

        guard let categoryIndex = budget.categories.firstIndex(where: { $0.id == categoryID }) else {
            return .failure(.validation())
        }

        let transaction = BWTransaction(
            title: trimmedTitle,
            description: trimmedDescription,
            date: date,
            amount: amount
        )

        budget.categories[categoryIndex].transactions.append(transaction)

        switch normalizeActualAmounts(in: budget) {
            case .failure(let error):
                return .failure(error)
            case .success(let budget):
                return await saveBudget(budget, vault: vault, operation: .TransactionCreate(categoryId: categoryID, transactionId: transaction.id))
        }
    }

    public static func updateTransaction(
        in budget: BWBudget,
        transaction: BWTransaction,
        from sourceCategoryID: UUID,
        to destinationCategoryID: UUID,
        vault: BWVault
    ) async -> Result<BWBudget, BWError> {
        let trimmedTitle = transaction.title.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedTitle.isEmpty, transaction.amount > 0 else {
            return .failure(.validation())
        }

        var budget = budget

        guard let sourceCategoryIndex = budget.categories.firstIndex(where: { $0.id == sourceCategoryID }),
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

            guard let destinationCategoryIndex = budget.categories.firstIndex(where: { $0.id == destinationCategoryID }) else {
                return .failure(.validation())
            }

            budget.categories[destinationCategoryIndex].transactions.append(updatedTransaction)
        }

        switch normalizeActualAmounts(in: budget) {
            case .failure(let error):
                return .failure(error)
            case .success(let budget):
                return await saveBudget(
                    budget,
                    vault: vault,
                    operation: .TransactionUpdate(
                        sourceCategoryId: sourceCategoryID,
                        destinationCategoryId: destinationCategoryID,
                        transactionId: updatedTransaction.id
                    )
                )
        }
    }

    public static func deleteTransaction(
        in budget: BWBudget,
        transactionID: UUID,
        from categoryID: UUID,
        vault: BWVault
    ) async -> Result<BWBudget, BWError> {
        var budget = budget

        guard let categoryIndex = budget.categories.firstIndex(where: { $0.id == categoryID }),
              let transactionIndex = budget.categories[categoryIndex].transactions.firstIndex(where: { $0.id == transactionID })
        else {
            return .failure(.validation())
        }

        budget.categories[categoryIndex].transactions.remove(at: transactionIndex)

        switch normalizeActualAmounts(in: budget) {
            case .failure(let error):
                return .failure(error)
            case .success(let budget):
                return await saveBudget(budget, vault: vault, operation: .TransactionDelete(categoryId: categoryID, transactionId: transactionID))
        }
    }

    static func orderedCategories(
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

    private static func nextOrdinal(
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

    private static func normalizeCategoryOrdinals(
        in budget: inout BWBudget,
        for categoryType: BWCategoryType
    ) {
        let categories = orderedCategoryIndexes(in: budget, for: categoryType)

        for (ordinal, categoryIndex) in categories.map(\.index).enumerated() {
            budget.categories[categoryIndex].ordinal = ordinal
        }
    }

    private static func normalizeActualAmounts(in budget: BWBudget) -> Result<BWBudget, BWError> {
        var budget = budget

        guard recalculateActualAmounts(in: &budget) else {
            return .failure(.amountOverflow)
        }

        return .success(budget)
    }

    private static func mergeBudget(
        _ budget: BWBudget,
        with budgetOnDisk: BWBudget
    ) -> Result<BWBudget, BWError> {
        // The current on-disk budget is loaded here so conflict-aware merging can compare
        // against the latest file contents without changing today's overwrite behavior.
        .success(budget)
    }

    private static func recalculateActualAmounts(in budget: inout BWBudget) -> Bool {
        for index in budget.categories.indices {
            guard let amountActual = UInt64.sumMoneyAmounts(
                budget.categories[index].transactions.map(\.amount)
            ) else {
                return false
            }

            budget.categories[index].amountActual = amountActual
        }

        return true
    }

    private static func normalizeDirectoryReadResult(
        _ result: BWBudgetDirectoryReadResult
    ) -> BWBudgetDirectoryReadResult {
        var budgets: [BWBudget] = []
        var skippedFiles = result.skippedFiles

        for budget in result.budgets {
            switch normalizeActualAmounts(in: budget) {
                case .failure:
                    skippedFiles.append(budget.url?.lastPathComponent ?? budget.title)
                case .success(let budget):
                    budgets.append(budget)
            }
        }

        return BWBudgetDirectoryReadResult(
            budgets: budgets,
            skippedFiles: skippedFiles
        )
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

public extension BWBudget {
    func orderedCategories(for categoryType: BWCategoryType? = nil) -> [BWCategory] {
        BWBudgetService.orderedCategories(in: self, for: categoryType)
    }
}
