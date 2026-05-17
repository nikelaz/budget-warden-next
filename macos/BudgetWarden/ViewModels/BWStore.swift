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
import Combine

@MainActor
class BWStore: ObservableObject {
    private let currencyKey = "BW_CURRENCY"

    @Published var currentBudget: BWBudget? = nil
    @Published var budgetsInVault: [BWBudget] = []
    @Published var budgetsInVaultLoaded: Bool = false
    @Published var isVaultNotSet: Bool = false

    // Currency
    @Published var selectedCurrency: BWCurrency {
        didSet {
            UserDefaults.standard.set(selectedCurrency.rawValue, forKey: currencyKey)
        }
    }

    private let autosaveDelayNanoseconds: UInt64 = 800_000_000
    private var pendingBudgetSaveTasks: [UUID: Task<Void, Never>] = [:]
    private var pendingBudgetSaveSnapshots: [UUID: BWBudget] = [:]

    var vault: BWVault = BWVault()

    init() {
        let savedCurrency = UserDefaults.standard.string(forKey: currencyKey)
            .flatMap(BWCurrency.init(rawValue:))
        _selectedCurrency = Published(initialValue: savedCurrency ?? .defaultCurrency)
    }
    
    func selectVaultFolder() async {
        let selectVaultRes = await vault.selectVaultFolder()
       
        switch selectVaultRes {
            case .success:
                await loadBudgetsFromVault()
            case .failure:
                break
        }
    }

    func loadBudgetsFromVault() async {
        budgetsInVault = []
        budgetsInVaultLoaded = false
        isVaultNotSet = false

        let vaultReadRes = await vault.readBudgetsFromVault()

        switch vaultReadRes {
            case .failure:
                isVaultNotSet = true
                return
            case .success(let budgets):
                budgetsInVault = budgets
                budgetsInVaultLoaded = true
        }
    }

    func reloadBudgetsFromVault() async {
        let vaultReadRes = await vault.readBudgetsFromVault()

        switch vaultReadRes {
            case .failure:
                return
            case .success(let budgets):
                budgetsInVault = budgets
        }
    }

    func createBudget(
        title: String,
        template: BudgetTemplateSelection,
        windowStore: BWWindowStore
    ) async -> Bool {
        if await vault.currentURL() == nil {
            await selectVaultFolder()
        }

        let budgetCreationRes = await BWBudgetService.createBudget(
            title: title,
            template: template,
            vault: vault,
            budgetsInVault: budgetsInVault
        )

        switch budgetCreationRes {
            case .failure(let error):
                windowStore.closeBudgetDialog()
                windowStore.setError(error)
                return false
            case .success(let budget):
                selectBudget(budget)
        }

        return true
    }

    func selectBudget(_ budget: BWBudget) {
        currentBudget = budget
    }

    func createCategory(
        title: String,
        plannedAmount: UInt64,
        categoryType: BWCategoryType,
        windowStore: BWWindowStore
    ) async -> Bool {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedTitle.isEmpty, var budget = currentBudget else {
            return false
        }

        let category = BWCategory(
            ordinal: nextOrdinal(in: budget, for: categoryType),
            title: trimmedTitle,
            amountPlanned: plannedAmount,
            categoryType: categoryType
        )

        budget.categories.append(category)
        currentBudget = budget
        updateBudgetInVaultList(budget)
        cancelPendingBudgetSave(for: budget.id)

        let saveBudgetRes = await BWBudgetService.saveBudget(
            budget,
            vault: vault
        )

        switch saveBudgetRes {
            case .failure(let error):
                windowStore.setError(error)
                return false
            case .success:
                return true
        }
    }

    func updateCategory(_ updatedCategory: BWCategory, windowStore: BWWindowStore) {
        guard var budget = currentBudget else {
            return
        }

        guard let index = budget.categories.firstIndex(where: { $0.id == updatedCategory.id }) else {
            return
        }

        let oldCategoryType = budget.categories[index].categoryType
        var category = updatedCategory

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

        updateBudget(budget, windowStore: windowStore)
    }

    func canMoveCategory(_ category: BWCategory, by offset: Int) -> Bool {
        guard abs(offset) == 1, let budget = currentBudget else {
            return false
        }

        let categories = orderedCategoryIndexes(
            in: budget,
            for: category.categoryType
        )

        guard let index = categories.firstIndex(where: { $0.category.id == category.id }) else {
            return false
        }

        let targetIndex = index + offset

        return targetIndex >= 0 && targetIndex < categories.count
    }

    func moveCategory(_ category: BWCategory, by offset: Int, windowStore: BWWindowStore) {
        guard abs(offset) == 1, var budget = currentBudget else {
            return
        }

        var categories = orderedCategoryIndexes(
            in: budget,
            for: category.categoryType
        )

        guard let index = categories.firstIndex(where: { $0.category.id == category.id }) else {
            return
        }

        let targetIndex = index + offset

        guard targetIndex >= 0 && targetIndex < categories.count else {
            return
        }

        categories.swapAt(index, targetIndex)

        for (ordinal, categoryIndex) in categories.map(\.index).enumerated() {
            budget.categories[categoryIndex].ordinal = ordinal
        }

        updateBudget(budget, windowStore: windowStore)
    }

    func deleteCategory(_ category: BWCategory, windowStore: BWWindowStore) {
        guard var budget = currentBudget else {
            return
        }

        guard let index = budget.categories.firstIndex(where: { $0.id == category.id }) else {
            return
        }

        let categoryType = budget.categories[index].categoryType

        budget.categories.remove(at: index)
        normalizeCategoryOrdinals(in: &budget, for: categoryType)

        updateBudget(budget, windowStore: windowStore)
    }

    func createTransaction(
        categoryID: UUID,
        title: String,
        description: String,
        date: Date,
        amount: UInt64,
        windowStore: BWWindowStore
    ) -> Bool {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDescription = description.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedTitle.isEmpty, amount > 0, var budget = currentBudget else {
            return false
        }

        guard let categoryIndex = budget.categories.firstIndex(where: { $0.id == categoryID }) else {
            return false
        }

        guard UInt64.max - budget.categories[categoryIndex].amountActual >= amount else {
            return false
        }

        let transaction = BWTransaction(
            title: trimmedTitle,
            description: trimmedDescription,
            date: date,
            amount: amount
        )

        budget.categories[categoryIndex].transactions.append(transaction)
        budget.categories[categoryIndex].amountActual += amount

        updateBudget(budget, windowStore: windowStore)
        return true
    }

    func updateTransaction(
        categoryID: UUID,
        transaction: BWTransaction,
        windowStore: BWWindowStore
    ) -> Bool {
        let trimmedTitle = transaction.title.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedTitle.isEmpty, transaction.amount > 0, var budget = currentBudget else {
            return false
        }

        guard let categoryIndex = budget.categories.firstIndex(where: { $0.id == categoryID }) else {
            return false
        }

        guard let transactionIndex = budget.categories[categoryIndex].transactions.firstIndex(where: { $0.id == transaction.id }) else {
            return false
        }

        let oldTransaction = budget.categories[categoryIndex].transactions[transactionIndex]

        if transaction.amount >= oldTransaction.amount {
            let increase = transaction.amount - oldTransaction.amount

            guard UInt64.max - budget.categories[categoryIndex].amountActual >= increase else {
                windowStore.setError(.saveFailed())
                return false
            }

            budget.categories[categoryIndex].amountActual += increase
        }
        else {
            budget.categories[categoryIndex].amountActual -= oldTransaction.amount - transaction.amount
        }

        budget.categories[categoryIndex].transactions[transactionIndex] = BWTransaction(
            id: transaction.id,
            title: trimmedTitle,
            description: transaction.description.trimmingCharacters(in: .whitespacesAndNewlines),
            date: transaction.date,
            amount: transaction.amount
        )

        updateBudget(budget, windowStore: windowStore)
        return true
    }

    func deleteTransaction(
        categoryID: UUID,
        transactionID: UUID,
        windowStore: BWWindowStore
    ) {
        guard var budget = currentBudget else {
            return
        }

        guard let categoryIndex = budget.categories.firstIndex(where: { $0.id == categoryID }) else {
            return
        }

        guard let transactionIndex = budget.categories[categoryIndex].transactions.firstIndex(where: { $0.id == transactionID }) else {
            return
        }

        let transaction = budget.categories[categoryIndex].transactions.remove(at: transactionIndex)
        budget.categories[categoryIndex].amountActual -= transaction.amount

        updateBudget(budget, windowStore: windowStore)
    }

    func moveTransaction(
        transactionID: UUID,
        from sourceCategoryID: UUID,
        to destinationCategoryID: UUID,
        windowStore: BWWindowStore
    ) -> Bool {
        guard sourceCategoryID != destinationCategoryID else {
            return true
        }

        guard var budget = currentBudget else {
            return false
        }

        guard let sourceCategoryIndex = budget.categories.firstIndex(where: { $0.id == sourceCategoryID }) else {
            return false
        }

        guard let destinationCategoryIndex = budget.categories.firstIndex(where: { $0.id == destinationCategoryID }) else {
            return false
        }

        guard let transactionIndex = budget.categories[sourceCategoryIndex].transactions.firstIndex(where: { $0.id == transactionID }) else {
            return false
        }

        let transaction = budget.categories[sourceCategoryIndex].transactions[transactionIndex]

        guard UInt64.max - budget.categories[destinationCategoryIndex].amountActual >= transaction.amount else {
            windowStore.setError(.saveFailed())
            return false
        }

        budget.categories[sourceCategoryIndex].transactions.remove(at: transactionIndex)
        budget.categories[sourceCategoryIndex].amountActual -= transaction.amount
        budget.categories[destinationCategoryIndex].transactions.append(transaction)
        budget.categories[destinationCategoryIndex].amountActual += transaction.amount

        updateBudget(budget, windowStore: windowStore)
        return true
    }

    private func updateBudget(_ budget: BWBudget, windowStore: BWWindowStore) {
        currentBudget = budget
        updateBudgetInVaultList(budget)
        scheduleBudgetSave(budget, windowStore: windowStore)
    }

    private func nextOrdinal(in budget: BWBudget, for categoryType: BWCategoryType, except categoryID: UUID) -> Int {
        let maxOrdinal = budget.categories
            .filter { $0.categoryType == categoryType && $0.id != categoryID }
            .map(\.ordinal)
            .max()

        return (maxOrdinal ?? -1) + 1
    }

    private func nextOrdinal(in budget: BWBudget, for categoryType: BWCategoryType) -> Int {
        nextOrdinal(in: budget, for: categoryType, except: UUID())
    }

    private func normalizeCategoryOrdinals(in budget: inout BWBudget, for categoryType: BWCategoryType) {
        let categories = orderedCategoryIndexes(
            in: budget,
            for: categoryType
        )

        for (ordinal, categoryIndex) in categories.map(\.index).enumerated() {
            budget.categories[categoryIndex].ordinal = ordinal
        }
    }

    private func orderedCategoryIndexes(
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

    func saveCurrentBudgetNow(budgetID: UUID? = nil, windowStore: BWWindowStore) async {
        if let budgetID {
            pendingBudgetSaveTasks[budgetID]?.cancel()
            pendingBudgetSaveTasks[budgetID] = nil

            if let budget = pendingBudgetSaveSnapshots.removeValue(forKey: budgetID) {
                await saveBudget(budget, windowStore: windowStore)
                return
            }

            guard currentBudget?.id == budgetID else {
                return
            }
        }
        else {
            pendingBudgetSaveTasks.values.forEach { $0.cancel() }
            pendingBudgetSaveTasks = [:]
            pendingBudgetSaveSnapshots = [:]
        }

        await saveCurrentBudget(windowStore: windowStore)
    }

    private func scheduleBudgetSave(_ budget: BWBudget, windowStore: BWWindowStore) {
        pendingBudgetSaveTasks[budget.id]?.cancel()
        pendingBudgetSaveSnapshots[budget.id] = budget

        pendingBudgetSaveTasks[budget.id] = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: self?.autosaveDelayNanoseconds ?? 800_000_000)
            }
            catch {
                return
            }

            self?.pendingBudgetSaveTaskCompleted(for: budget.id)
            await self?.saveBudget(budget, windowStore: windowStore)
        }
    }

    private func saveCurrentBudget(windowStore: BWWindowStore) async {
        guard let budget = currentBudget else {
            return
        }

        await saveBudget(budget, windowStore: windowStore)
    }

    private func saveBudget(_ budget: BWBudget, windowStore: BWWindowStore) async {
        let saveBudgetRes = await BWBudgetService.saveBudget(
            budget,
            vault: vault
        )

        switch saveBudgetRes {
            case .failure(let error):
                windowStore.setError(error)
            case .success:
                break
        }
    }

    private func pendingBudgetSaveTaskCompleted(for budgetID: UUID) {
        pendingBudgetSaveTasks[budgetID] = nil
        pendingBudgetSaveSnapshots[budgetID] = nil
    }

    private func cancelPendingBudgetSave(for budgetID: UUID) {
        pendingBudgetSaveTasks[budgetID]?.cancel()
        pendingBudgetSaveTasks[budgetID] = nil
        pendingBudgetSaveSnapshots[budgetID] = nil
    }

    private func updateBudgetInVaultList(_ budget: BWBudget) {
        guard let index = budgetsInVault.firstIndex(where: { $0.id == budget.id }) else {
            return
        }

        budgetsInVault[index] = budget
    }

    func removeBudget(url: URL, windowStore: BWWindowStore) async {
        let removeBudgetRes = await vault.removeBudgetFromVault(url: url)

        switch removeBudgetRes {
            case .failure(let error):
                windowStore.setError(error) 
                return
            case .success:
                await reloadBudgetsFromVault()
        }
    }

    func openBudget(windowStore: BWWindowStore) -> Bool {
        guard let openFileRes  = BWFiles.openAndReadFile() else {
            return false
        }

        let budgetRes = BWCodec.decodeBudget(json: openFileRes.contents, url: openFileRes.url)

        switch budgetRes {
            case .failure(let error):
                windowStore.setError(error)
                return false
            case .success(let budget):
                currentBudget = budget
        }
        
        return true
    }
}
