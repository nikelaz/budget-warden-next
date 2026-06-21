/*
 * Budget Warden
 * Copyright (c) 2026 Lazarov & Co EOOD
 * Author: Nikola Lazarov
 *
 * Licensed under the Source-Available Educational License.
 * See the LICENSE file in the project root for full terms.
 *
 */

import AppleCore
import Foundation
import Observation

@MainActor
@Observable
final class BWAppStore {
    private let lastOpenedBudgetIDKey = "BWI_LAST_OPENED_BUDGET_ID"
    private let currencyKey = "BWI_CURRENCY"

    let vault = BWVault()

    private(set) var budgets: [BWBudget] = []
    private(set) var vaultLocation: BWVaultLocation = .local
    private(set) var vaultURL: URL?
    private(set) var skippedFiles: [String] = []

    var selectedBudgetID: UUID?
    var errorMessage: String?
    var isLoadingBudgets = false
    var selectedCurrency: BWCurrency {
        didSet {
            UserDefaults.standard.set(selectedCurrency.rawValue, forKey: currencyKey)
        }
    }

    init() {
        let savedCurrency = UserDefaults.standard.string(forKey: currencyKey)
            .flatMap(BWCurrency.init(rawValue:))

        selectedCurrency = savedCurrency ?? .defaultCurrency
    }

    var selectedBudget: BWBudget? {
        guard let selectedBudgetID else {
            return nil
        }

        return budget(withID: selectedBudgetID)
    }

    func budget(withID budgetID: UUID) -> BWBudget? {
        budgets.first { $0.id == budgetID }
    }

    func createCategory(
        in budgetID: UUID,
        title: String,
        plannedAmount: UInt64,
        categoryType: BWCategoryType
    ) async -> Bool {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedTitle.isEmpty,
              var budget = budget(withID: budgetID)
        else {
            return false
        }

        let category = BWCategory(
            ordinal: nextOrdinal(in: budget, for: categoryType),
            title: trimmedTitle,
            amountPlanned: plannedAmount,
            categoryType: categoryType
        )

        budget.categories.append(category)
        return await updateAndSaveBudget(budget)
    }

    func updateBudgetTitle(_ title: String, for budgetID: UUID) async -> Bool {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedTitle.isEmpty,
              var budget = budget(withID: budgetID)
        else {
            return false
        }

        budget.title = trimmedTitle
        return await updateAndSaveBudget(budget)
    }

    func updateCategory(_ updatedCategory: BWCategory, in budgetID: UUID) async -> Bool {
        let trimmedTitle = updatedCategory.title.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedTitle.isEmpty,
              var budget = budget(withID: budgetID),
              let index = budget.categories.firstIndex(where: { $0.id == updatedCategory.id })
        else {
            return false
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

        return await updateAndSaveBudget(budget)
    }

    func deleteCategory(_ category: BWCategory, in budgetID: UUID) async {
        guard var budget = budget(withID: budgetID),
              let index = budget.categories.firstIndex(where: { $0.id == category.id })
        else {
            return
        }

        let categoryType = budget.categories[index].categoryType

        budget.categories.remove(at: index)
        normalizeCategoryOrdinals(in: &budget, for: categoryType)

        _ = await updateAndSaveBudget(budget)
    }

    func createTransaction(
        in budgetID: UUID,
        categoryID: UUID,
        title: String,
        description: String,
        date: Date,
        amount: UInt64
    ) async -> Bool {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDescription = description.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedTitle.isEmpty,
              amount > 0,
              var budget = budget(withID: budgetID),
              let categoryIndex = budget.categories.firstIndex(where: { $0.id == categoryID })
        else {
            return false
        }

        let transaction = BWTransaction(
            title: trimmedTitle,
            description: trimmedDescription,
            date: date,
            amount: amount
        )

        budget.categories[categoryIndex].transactions.append(transaction)
        return await updateAndSaveBudget(budget)
    }

    func updateTransaction(
        _ transaction: BWTransaction,
        in budgetID: UUID,
        from sourceCategoryID: UUID,
        to destinationCategoryID: UUID
    ) async -> Bool {
        let trimmedTitle = transaction.title.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedTitle.isEmpty,
              transaction.amount > 0,
              var budget = budget(withID: budgetID),
              let sourceCategoryIndex = budget.categories.firstIndex(where: { $0.id == sourceCategoryID }),
              let destinationCategoryIndex = budget.categories.firstIndex(where: { $0.id == destinationCategoryID }),
              let transactionIndex = budget.categories[sourceCategoryIndex].transactions.firstIndex(where: { $0.id == transaction.id })
        else {
            return false
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

        return await updateAndSaveBudget(budget)
    }

    func deleteTransaction(
        _ transaction: BWTransaction,
        in budgetID: UUID,
        from categoryID: UUID
    ) async {
        guard var budget = budget(withID: budgetID),
              let categoryIndex = budget.categories.firstIndex(where: { $0.id == categoryID }),
              let transactionIndex = budget.categories[categoryIndex].transactions.firstIndex(where: { $0.id == transaction.id })
        else {
            return
        }

        budget.categories[categoryIndex].transactions.remove(at: transactionIndex)
        _ = await updateAndSaveBudget(budget)
    }

    func refreshVaultState() async {
        vaultLocation = await vault.currentLocation()
        vaultURL = await vault.currentURL()
    }

    func loadBudgets() async {
        isLoadingBudgets = true
        defer {
            isLoadingBudgets = false
        }

        await refreshVaultState()

        switch await vault.readBudgetsFromVault() {
            case .failure(let error):
                budgets = []
                selectedBudgetID = nil
                errorMessage = error.localizedDescription
            case .success(let result):
                budgets = result.budgets
                skippedFiles = result.skippedFiles
                restoreSelection()
        }
    }

    func selectBudget(withID budgetID: UUID) {
        guard budget(withID: budgetID) != nil else {
            return
        }

        selectedBudgetID = budgetID
        UserDefaults.standard.set(budgetID.uuidString, forKey: lastOpenedBudgetIDKey)
    }

    func open(_ budget: BWBudget) {
        if let index = budgets.firstIndex(where: { $0.id == budget.id }) {
            budgets[index] = budget
        }
        else {
            budgets.insert(budget, at: 0)
        }

        selectBudget(withID: budget.id)
    }

    func openBudget(at url: URL) {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let json = try String(contentsOf: url, encoding: .utf8)

            switch BWCodec.decodeBudget(json: json, url: url) {
                case .success(let budget):
                    open(budget)
                case .failure(let error):
                    errorMessage = error.localizedDescription
            }
        }
        catch {
            errorMessage = BWError.readingFile(underlying: error).localizedDescription
        }
    }

    func createBudget(title: String, template: BWTemplateSelection) async -> Bool {
        switch await BWService.createBudget(
            title: title,
            template: template,
            vault: vault,
            budgetsInVault: budgets
        ) {
            case .failure(let error):
                errorMessage = error.localizedDescription
                return false
            case .success(let budget):
                open(budget)
                await loadBudgets()
                selectBudget(withID: budget.id)
                return true
        }
    }

    func deleteBudget(_ budget: BWBudget) async {
        guard let url = budget.url else {
            budgets.removeAll { $0.id == budget.id }
            clearSelectionIfNeeded(deletedBudgetID: budget.id)
            return
        }

        switch await vault.removeBudgetFromVault(url: url) {
            case .failure(let error):
                errorMessage = error.localizedDescription
            case .success:
                budgets.removeAll { $0.id == budget.id }
                clearSelectionIfNeeded(deletedBudgetID: budget.id)
        }
    }

    func deleteBudgets(at offsets: IndexSet) async {
        let budgetsToDelete = offsets.compactMap { index in
            budgets.indices.contains(index) ? budgets[index] : nil
        }

        for budget in budgetsToDelete {
            await deleteBudget(budget)
        }
    }

    func setVaultLocation(_ location: BWVaultLocation) async {
        switch await vault.setLocation(location) {
            case .failure(let error):
                errorMessage = error.localizedDescription
            case .success:
                await loadBudgets()
        }

        await refreshVaultState()
    }

    func setLocalVaultFolder(_ url: URL) async {
        switch await vault.setLocalVaultFolder(url) {
            case .failure(let error):
                errorMessage = error.localizedDescription
            case .success:
                await loadBudgets()
        }

        await refreshVaultState()
    }

    private func restoreSelection() {
        guard !budgets.isEmpty else {
            selectedBudgetID = nil
            return
        }

        if let selectedBudgetID, budget(withID: selectedBudgetID) != nil {
            return
        }

        if let idString = UserDefaults.standard.string(forKey: lastOpenedBudgetIDKey),
           let budgetID = UUID(uuidString: idString),
           budget(withID: budgetID) != nil {
            selectedBudgetID = budgetID
            return
        }

        selectedBudgetID = budgets.first?.id
    }

    private func updateAndSaveBudget(_ budget: BWBudget) async -> Bool {
        var normalizedBudget = budget

        guard BWCodec.normalizeActualAmounts(in: &normalizedBudget) else {
            errorMessage = BWError.amountOverflow.localizedDescription
            return false
        }

        upsertBudget(normalizedBudget)

        switch await BWService.saveBudget(normalizedBudget, vault: vault) {
            case .failure(let error):
                errorMessage = error.localizedDescription
                return false
            case .success:
                return true
        }
    }

    private func upsertBudget(_ budget: BWBudget) {
        if let index = budgets.firstIndex(where: { $0.id == budget.id }) {
            budgets[index] = budget
        }
        else {
            budgets.append(budget)
        }
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
        let categories = orderedCategoryIndexes(in: budget, for: categoryType)

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

    private func clearSelectionIfNeeded(deletedBudgetID: UUID) {
        guard selectedBudgetID == deletedBudgetID else {
            return
        }

        selectedBudgetID = budgets.first?.id

        if let selectedBudgetID {
            UserDefaults.standard.set(selectedBudgetID.uuidString, forKey: lastOpenedBudgetIDKey)
        }
        else {
            UserDefaults.standard.removeObject(forKey: lastOpenedBudgetIDKey)
        }
    }
}
