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
    private let deviceIDKey = "BWI_DEVICE_ID"

    let vault = BWVault()

    private(set) var budgets: [BWBudget] = []
    private(set) var vaultLocation: BWVaultLocation = .iCloud
    private(set) var vaultURL: URL?
    private(set) var skippedFiles: [String] = []
    var saveConflict: BWBudgetSaveConflict?

    var selectedBudgetID: UUID?
    var errorMessage: String?
    var isLoadingBudgets = false
    var selectedCurrency: BWCurrency {
        didSet {
            UserDefaults.standard.set(selectedCurrency.rawValue, forKey: currencyKey)
        }
    }
    private let deviceID: String
    private var baseBudgetSnapshots: [UUID: BWBudget] = [:]

    init() {
        let savedCurrency = UserDefaults.standard.string(forKey: currencyKey)
            .flatMap(BWCurrency.init(rawValue:))

        selectedCurrency = savedCurrency ?? .defaultCurrency

        if let savedDeviceID = UserDefaults.standard.string(forKey: deviceIDKey) {
            deviceID = savedDeviceID
        }
        else {
            let newDeviceID = UUID().uuidString
            UserDefaults.standard.set(newDeviceID, forKey: deviceIDKey)
            deviceID = newDeviceID
        }
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
        guard let budget = budget(withID: budgetID) else {
            return false
        }

        return await mutateAndSaveBudget(BWBudgetMutation.createCategory(
            in: budget,
            title: title,
            plannedAmount: plannedAmount,
            categoryType: categoryType
        ))
    }

    func updateBudgetTitle(_ title: String, for budgetID: UUID) async -> Bool {
        guard let budget = budget(withID: budgetID) else {
            return false
        }

        return await mutateAndSaveBudget(BWBudgetMutation.updateBudgetTitle(
            in: budget,
            title: title
        ))
    }

    func updateCategory(_ updatedCategory: BWCategory, in budgetID: UUID) async -> Bool {
        guard let budget = budget(withID: budgetID) else {
            return false
        }

        return await mutateAndSaveBudget(BWBudgetMutation.updateCategory(
            in: budget,
            category: updatedCategory
        ))
    }

    func deleteCategory(_ category: BWCategory, in budgetID: UUID) async {
        guard let budget = budget(withID: budgetID) else {
            return
        }

        _ = await mutateAndSaveBudget(BWBudgetMutation.deleteCategory(
            in: budget,
            categoryID: category.id
        ))
    }

    func moveCategories(
        in budgetID: UUID,
        for categoryType: BWCategoryType,
        fromOffsets sourceOffsets: IndexSet,
        toOffset destination: Int
    ) async -> Bool {
        guard let budget = budget(withID: budgetID) else {
            return false
        }

        return await mutateAndSaveBudget(BWBudgetMutation.moveCategories(
            in: budget,
            for: categoryType,
            fromOffsets: sourceOffsets,
            toOffset: destination
        ))
    }

    func createTransaction(
        in budgetID: UUID,
        categoryID: UUID,
        title: String,
        description: String,
        date: Date,
        amount: UInt64
    ) async -> Bool {
        guard let budget = budget(withID: budgetID) else {
            return false
        }

        return await mutateAndSaveBudget(BWBudgetMutation.createTransaction(
            in: budget,
            categoryID: categoryID,
            title: title,
            description: description,
            date: date,
            amount: amount
        ))
    }

    func updateTransaction(
        _ transaction: BWTransaction,
        in budgetID: UUID,
        from sourceCategoryID: UUID,
        to destinationCategoryID: UUID
    ) async -> Bool {
        guard let budget = budget(withID: budgetID) else {
            return false
        }

        return await mutateAndSaveBudget(BWBudgetMutation.updateTransaction(
            in: budget,
            transaction: transaction,
            from: sourceCategoryID,
            to: destinationCategoryID
        ))
    }

    func deleteTransaction(
        _ transaction: BWTransaction,
        in budgetID: UUID,
        from categoryID: UUID
    ) async {
        guard let budget = budget(withID: budgetID) else {
            return
        }

        _ = await mutateAndSaveBudget(BWBudgetMutation.deleteTransaction(
            in: budget,
            transactionID: transaction.id,
            from: categoryID
        ))
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
                rememberBaseSnapshots(for: result.budgets)
                skippedFiles = result.skippedFiles
                restoreSelection()
        }
    }

    func selectBudget(withID budgetID: UUID) {
        guard let budget = budget(withID: budgetID) else {
            return
        }

        rememberBaseSnapshot(for: budget)
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
                rememberBaseSnapshot(for: budget)
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
            budgetsInVault: budgets,
            deviceID: deviceID
        ) {
            case .failure(let error):
                errorMessage = error.localizedDescription
                return false
            case .success(let budget):
                rememberBaseSnapshot(for: budget)
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

        switch await BWService.saveBudget(
            normalizedBudget,
            baseBudget: baseBudgetSnapshots[normalizedBudget.id],
            vault: vault,
            deviceID: deviceID
        ) {
            case .failure(let error):
                errorMessage = error.localizedDescription
                return false
            case .success(let outcome):
                return handleSaveOutcome(outcome)
        }
    }

    private func mutateAndSaveBudget(_ result: Result<BWBudget, BWError>) async -> Bool {
        switch result {
            case .failure(.validation):
                return false
            case .failure(let error):
                errorMessage = error.localizedDescription
                return false
            case .success(let budget):
                return await updateAndSaveBudget(budget)
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

    func resolveSaveConflict(
        _ conflict: BWBudgetSaveConflict,
        choice: BWBudgetConflictChoice
    ) async {
        let resolveResult: Result<BWBudgetSaveOutcome, BWError>

        if await vault.containsBudgetFile(url: conflict.fileURL) {
            resolveResult = await vault.resolveBudgetFileConflict(
                conflict,
                choice: choice,
                deviceID: deviceID
            )
        }
        else {
            resolveResult = BWBudgetFileStore.resolveSaveConflict(
                conflict,
                choice: choice,
                modifiedByDeviceID: deviceID
            )
        }

        switch resolveResult {
            case .failure(let error):
                errorMessage = error.localizedDescription
            case .success(let outcome):
                if handleSaveOutcome(outcome) {
                    saveConflict = nil
                }
        }
    }

    private func handleSaveOutcome(_ outcome: BWBudgetSaveOutcome) -> Bool {
        switch outcome {
            case .saved(let savedBudget):
                upsertBudget(savedBudget)
                rememberBaseSnapshot(for: savedBudget)
                return true
            case .conflict(let conflict):
                saveConflict = conflict
                return false
        }
    }

    private func rememberBaseSnapshots(for budgets: [BWBudget]) {
        for budget in budgets where selectedBudgetID != budget.id {
            rememberBaseSnapshot(for: budget)
        }
    }

    private func rememberBaseSnapshot(for budget: BWBudget) {
        baseBudgetSnapshots[budget.id] = budget
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
