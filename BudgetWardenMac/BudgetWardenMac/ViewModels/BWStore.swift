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
import AppKit
import UniformTypeIdentifiers
import BudgetWardenAppleCore

@MainActor
class BWStore: ObservableObject {
    private let currencyKey = "BW_CURRENCY"
    private static let iCloudContainerIdentifier = "iCloud.com.lazarovco.BudgetWarden"
    private static let defaultVaultFolderName = "Budget Warden Vaults"

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

    var vault: BWVault = BWVault(configuration: BWStore.vaultConfiguration)

    private static var vaultConfiguration: BWVaultConfiguration {
        BWVaultConfiguration(
            vaultLocationKey: "BW_VAULT_LOCATION",
            localVaultBookmarkKey: "BW_LOCAL_VAULT_BOOKMARK",
            iCloudVaultBookmarkKey: "BW_ICLOUD_VAULT_BOOKMARK",
            legacyLocalVaultBookmarkKey: "BW_VAULT_BOOKMARK",
            defaultVaultFolderName: defaultVaultFolderName,
            defaultLocation: UserDefaults.standard.data(forKey: "BW_VAULT_BOOKMARK") == nil ? .iCloud : .local,
            iCloudContainerIdentifier: iCloudContainerIdentifier,
            allowsICloudDriveFallback: true,
            localBookmarkCreationOptions: .withSecurityScope,
            localBookmarkResolutionOptions: .withSecurityScope,
            iCloudBookmarkResolutionOptions: .withSecurityScope,
            deleteBudgetFile: { url in
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            }
        )
    }

    init() {
        let savedCurrency = UserDefaults.standard.string(forKey: currencyKey)
            .flatMap(BWCurrency.init(rawValue:))
        _selectedCurrency = Published(initialValue: savedCurrency ?? .defaultCurrency)
    }
    
    @discardableResult
    func selectVaultFolder() async -> BWError? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK else {
            return nil
        }

        guard let url = panel.url else {
            return .vaultNotSet()
        }

        let selectVaultRes = await vault.setLocalVaultFolder(url)
       
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

        let vaultReadRes = await BWBudgetService.loadBudgets(vault: vault)

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
        let vaultReadRes = await BWBudgetService.loadBudgets(vault: vault)

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
        template: BWTemplateSelection,
        windowStore: BWWindowStore
    ) async -> Bool {
        if await vault.currentURL() == nil {
            await selectVaultFolder()
        }

        let budgetCreationRes = await BWBudgetService.createBudget(
            title: title,
            template: template,
            budgetsInVault: budgetsInVault,
            vault: vault
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

        let result = await BWBudgetService.createCategory(
            in: budget,
            title: title,
            plannedAmount: plannedAmount,
            categoryType: categoryType,
            vault: vault
        )

        return handleBudgetMutation(
            result,
            windowStore: windowStore
        )
    }

    func updateCategory(_ updatedCategory: BWCategory, windowStore: BWWindowStore) async -> Bool {
        guard let budget = currentBudget else {
            return false
        }

        let result = await BWBudgetService.updateCategory(
            in: budget,
            category: updatedCategory,
            vault: vault
        )

        return handleBudgetMutation(
            result,
            windowStore: windowStore
        )
    }

    func canMoveCategory(_ category: BWCategory, by offset: Int) -> Bool {
        guard let budget = currentBudget else {
            return false
        }

        return BWBudgetService.canMoveCategory(category, in: budget, by: offset)
    }

    func moveCategory(_ category: BWCategory, by offset: Int, windowStore: BWWindowStore) async -> Bool {
        guard let budget = currentBudget else {
            return false
        }

        let result = await BWBudgetService.moveCategory(
            category,
            in: budget,
            by: offset,
            vault: vault
        )

        return handleBudgetMutation(
            result,
            windowStore: windowStore
        )
    }

    func deleteCategory(_ category: BWCategory, windowStore: BWWindowStore) async {
        guard let budget = currentBudget else {
            return
        }

        let result = await BWBudgetService.deleteCategory(
            in: budget,
            categoryID: category.id,
            vault: vault
        )

        _ = handleBudgetMutation(
            result,
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
    ) async -> Bool {
        guard let budget = currentBudget else {
            return false
        }

        let result = await BWBudgetService.createTransaction(
            in: budget,
            categoryID: categoryID,
            title: title,
            description: description,
            date: date,
            amount: amount,
            vault: vault
        )

        return handleBudgetMutation(
            result,
            windowStore: windowStore
        )
    }

    func updateTransaction(
        categoryID: UUID,
        transaction: BWTransaction,
        windowStore: BWWindowStore
    ) async -> Bool {
        guard let budget = currentBudget else {
            return false
        }

        let result = await BWBudgetService.updateTransaction(
            in: budget,
            transaction: transaction,
            from: categoryID,
            to: categoryID,
            vault: vault
        )

        return handleBudgetMutation(
            result,
            windowStore: windowStore
        )
    }

    func deleteTransaction(
        categoryID: UUID,
        transactionID: UUID,
        windowStore: BWWindowStore
    ) async {
        guard let budget = currentBudget else {
            return
        }

        let result = await BWBudgetService.deleteTransaction(
            in: budget,
            transactionID: transactionID,
            from: categoryID,
            vault: vault
        )

        _ = handleBudgetMutation(
            result,
            windowStore: windowStore
        )
    }

    func moveTransaction(
        transactionID: UUID,
        from sourceCategoryID: UUID,
        to destinationCategoryID: UUID,
        windowStore: BWWindowStore
    ) async -> Bool {
        guard sourceCategoryID != destinationCategoryID else {
            return true
        }

        guard let budget = currentBudget,
              let sourceCategory = budget.categories.first(where: { $0.id == sourceCategoryID }),
              let transaction = sourceCategory.transactions.first(where: { $0.id == transactionID })
        else {
            return false
        }

        let result = await BWBudgetService.updateTransaction(
            in: budget,
            transaction: transaction,
            from: sourceCategoryID,
            to: destinationCategoryID,
            vault: vault
        )

        return handleBudgetMutation(
            result,
            windowStore: windowStore
        )
    }

    private func handleBudgetMutation(
        _ result: Result<BWBudget, BWError>,
        windowStore: BWWindowStore
    ) -> Bool {
        switch result {
            case .failure(.validation):
                return false
            case .failure(let error):
                windowStore.setError(error)
                return false
            case .success(let budget):
                currentBudget = budget
                upsertBudgetInVaultList(budget)
                return true
        }
    }

    private func upsertBudgetInVaultList(_ budget: BWBudget) {
        guard let index = budgetsInVault.firstIndex(where: { $0.id == budget.id }) else {
            budgetsInVault.append(budget)
            return
        }

        budgetsInVault[index] = budget
    }

    func removeBudget(url: URL, windowStore: BWWindowStore) async {
        guard let budget = budgetsInVault.first(where: { $0.url == url }) else {
            let removeBudgetRes = await vault.removeBudgetFromVault(url: url)

            switch removeBudgetRes {
                case .failure(let error):
                    windowStore.setError(error)
                    return
                case .success:
                    await reloadBudgetsFromVault()
                    return
            }
        }

        let removeBudgetRes = await BWBudgetService.deleteBudget(
            budget,
            vault: vault
        )

        switch removeBudgetRes {
            case .failure(let error):
                windowStore.setError(error)
                return
            case .success:
                await reloadBudgetsFromVault()
        }
    }

    func openBudget(windowStore: BWWindowStore) async -> Bool {
        let budgetFileType = UTType(filenameExtension: BWFiles.budgetFileExtension) ?? .data
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [budgetFileType]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true

        guard panel.runModal() == .OK else {
            return false
        }

        guard let url = panel.url else {
            windowStore.setError(.readingFile())
            return false
        }

        return await openBudget(at: url, windowStore: windowStore)
    }

    func openBudget(at url: URL, windowStore: BWWindowStore) async -> Bool {
        let openBudgetRes = await BWBudgetService.openBudget(
            at: url,
            vault: vault
        )

        switch openBudgetRes {
            case .failure(let error):
                windowStore.setError(error)
                return false
            case .success(let result):
                if let vaultReadResult = result.vaultReadResult {
                    budgetsInVault = vaultReadResult.budgets
                    setVaultWarning(skippedFiles: vaultReadResult.skippedFiles)
                }

                currentBudget = result.budget
                return true
        }
    }
}
