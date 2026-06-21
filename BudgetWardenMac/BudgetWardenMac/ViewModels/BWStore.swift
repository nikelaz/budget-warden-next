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
import AppleCore

@MainActor
class BWStore: ObservableObject {
    private let currencyKey = "BW_CURRENCY"

    @Published var currentBudget: BWBudget? = nil
    @Published var budgetsInVault: [BWBudget] = []
    @Published var budgetsInVaultLoaded: Bool = false
    @Published var isVaultNotSet: Bool = false
    @Published var vaultWarningMessage: String? = nil

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
    
    @discardableResult
    func selectVaultFolder() async -> BWError? {
        let selectVaultRes = await vault.selectVaultFolder()
       
        switch selectVaultRes {
            case .success:
                await loadBudgetsFromVault()
                return nil
            case .failure(let error):
                if case .saveCancelled = error {
                    return nil
                }

                return error
        }
    }

    func clearVaultWarning() {
        vaultWarningMessage = nil
    }

    private func setVaultWarning(skippedFiles: [String]) {
        guard !skippedFiles.isEmpty else {
            vaultWarningMessage = nil
            return
        }

        let shownFiles = skippedFiles.prefix(3).joined(separator: ", ")
        let remainingCount = skippedFiles.count - min(skippedFiles.count, 3)

        if remainingCount > 0 {
            vaultWarningMessage = "Some budget files could not be loaded: \(shownFiles), and \(remainingCount) more."
        }
        else {
            vaultWarningMessage = "Some budget files could not be loaded: \(shownFiles)."
        }
    }

    func setVaultLocation(_ location: BWVaultLocation) async -> BWError? {
        let setLocationRes = await vault.setLocation(location)

        switch setLocationRes {
            case .success:
                await loadBudgetsFromVault()
                return nil
            case .failure(let error):
                return error
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
                vaultWarningMessage = nil
                return
            case .success(let result):
                budgetsInVault = result.budgets
                budgetsInVaultLoaded = true
                setVaultWarning(skippedFiles: result.skippedFiles)
        }
    }

    func reloadBudgetsFromVault() async {
        let vaultReadRes = await vault.readBudgetsFromVault()

        switch vaultReadRes {
            case .failure:
                return
            case .success(let result):
                budgetsInVault = result.budgets
                setVaultWarning(skippedFiles: result.skippedFiles)
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
                upsertBudgetInVaultList(budget)
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
        guard let budget = currentBudget else {
            return false
        }

        let mutationResult = BWBudgetMutation.createCategory(
            in: budget,
            title: title,
            plannedAmount: plannedAmount,
            categoryType: categoryType
        )

        guard case .success(let updatedBudget) = mutationResult else {
            return false
        }

        currentBudget = updatedBudget
        upsertBudgetInVaultList(updatedBudget)
        cancelPendingBudgetSave(for: updatedBudget.id)

        let saveBudgetRes = await BWBudgetService.saveBudget(
            updatedBudget,
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
        guard let budget = currentBudget else {
            return
        }

        updateBudget(
            BWBudgetMutation.updateCategory(in: budget, category: updatedCategory),
            windowStore: windowStore
        )
    }

    func canMoveCategory(_ category: BWCategory, by offset: Int) -> Bool {
        guard let budget = currentBudget else {
            return false
        }

        return BWBudgetMutation.canMoveCategory(category, in: budget, by: offset)
    }

    func moveCategory(_ category: BWCategory, by offset: Int, windowStore: BWWindowStore) {
        guard let budget = currentBudget else {
            return
        }

        updateBudget(
            BWBudgetMutation.moveCategory(category, in: budget, by: offset),
            windowStore: windowStore
        )
    }

    func deleteCategory(_ category: BWCategory, windowStore: BWWindowStore) {
        guard let budget = currentBudget else {
            return
        }

        updateBudget(
            BWBudgetMutation.deleteCategory(in: budget, categoryID: category.id),
            windowStore: windowStore
        )
    }

    func createTransaction(
        categoryID: UUID,
        title: String,
        description: String,
        date: Date,
        amount: UInt64,
        windowStore: BWWindowStore
    ) -> Bool {
        guard let budget = currentBudget else {
            return false
        }

        return updateBudget(
            BWBudgetMutation.createTransaction(
                in: budget,
                categoryID: categoryID,
                title: title,
                description: description,
                date: date,
                amount: amount
            ),
            windowStore: windowStore
        )
    }

    func updateTransaction(
        categoryID: UUID,
        transaction: BWTransaction,
        windowStore: BWWindowStore
    ) -> Bool {
        guard let budget = currentBudget else {
            return false
        }

        return updateBudget(
            BWBudgetMutation.updateTransaction(
                in: budget,
                transaction: transaction,
                from: categoryID,
                to: categoryID
            ),
            windowStore: windowStore
        )
    }

    func deleteTransaction(
        categoryID: UUID,
        transactionID: UUID,
        windowStore: BWWindowStore
    ) {
        guard let budget = currentBudget else {
            return
        }

        updateBudget(
            BWBudgetMutation.deleteTransaction(
                in: budget,
                transactionID: transactionID,
                from: categoryID
            ),
            windowStore: windowStore
        )
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

        guard let budget = currentBudget,
              let sourceCategory = budget.categories.first(where: { $0.id == sourceCategoryID }),
              let transaction = sourceCategory.transactions.first(where: { $0.id == transactionID })
        else {
            return false
        }

        return updateBudget(
            BWBudgetMutation.updateTransaction(
                in: budget,
                transaction: transaction,
                from: sourceCategoryID,
                to: destinationCategoryID
            ),
            windowStore: windowStore
        )
    }

    private func updateBudget(_ result: Result<BWBudget, BWError>, windowStore: BWWindowStore) -> Bool {
        switch result {
            case .failure(.validation):
                return false
            case .failure(let error):
                windowStore.setError(error)
                return false
            case .success(let budget):
                updateBudget(budget, windowStore: windowStore)
                return true
        }
    }

    private func updateBudget(_ budget: BWBudget, windowStore: BWWindowStore) {
        currentBudget = budget
        upsertBudgetInVaultList(budget)
        scheduleBudgetSave(budget, windowStore: windowStore)
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
        if let error = await saveBudgetReturningError(budget) {
            windowStore.setError(error)
        }
    }

    private func saveBudgetReturningError(_ budget: BWBudget) async -> BWError? {
        var normalizedBudget = budget

        guard BWCodec.normalizeActualAmounts(in: &normalizedBudget) else {
            return .amountOverflow
        }

        let saveBudgetRes = await BWBudgetService.saveBudget(
            normalizedBudget,
            vault: vault
        )

        switch saveBudgetRes {
            case .failure(let error):
                return error
            case .success:
                return nil
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

    private func upsertBudgetInVaultList(_ budget: BWBudget) {
        guard let index = budgetsInVault.firstIndex(where: { $0.id == budget.id }) else {
            budgetsInVault.append(budget)
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

    func flushPendingSaves() async -> BWError? {
        let budgets = Array(pendingBudgetSaveSnapshots.values)

        pendingBudgetSaveTasks.values.forEach { $0.cancel() }
        pendingBudgetSaveTasks = [:]
        pendingBudgetSaveSnapshots = [:]

        for budget in budgets {
            if let error = await saveBudgetReturningError(budget) {
                return error
            }
        }

        return nil
    }

    func openBudget(windowStore: BWWindowStore) async -> Bool {
        if let error = await flushPendingSaves() {
            windowStore.setError(error)
            return false
        }

        let openFileRes = BWFiles.openAndReadFile()

        switch openFileRes {
            case .failure(let error):
                windowStore.setError(error)
                return false
            case .success(nil):
                return false
            case .success(.some(let file)):
                let budgetRes = BWCodec.decodeBudget(json: file.contents, url: file.url)

                switch budgetRes {
                    case .failure(let error):
                        windowStore.setError(error)
                        return false
                    case .success(let budget):
                        currentBudget = budget
                }
        }

        return true
    }
}
