/*
 * Budget Warden
 * Copyright (c) 2026 Lazarov & Co EOOD
 * Author: Nikola Lazarov
 *
 * Licensed under the Source-Available Educational License.
 * See the LICENSE file in the project root for full terms.
 *
 */

import BudgetWardenAppleCore
import Foundation
import Observation

@MainActor
@Observable
final class BWStore {
    private let lastOpenedBudgetIDKey = "BWI_LAST_OPENED_BUDGET_ID"
    private let currencyKey = "BWI_CURRENCY"
    private static let iCloudContainerIdentifier = "iCloud.com.lazarovco.BudgetWarden"
    private static let defaultVaultFolderName = "Budget Warden Vaults"

    let vault = BWVault(configuration: BWStore.vaultConfiguration)

    private static var vaultConfiguration: BWVaultConfiguration {
        BWVaultConfiguration(
            vaultLocationKey: "BWI_VAULT_LOCATION",
            localVaultBookmarkKey: "BWI_LOCAL_VAULT_BOOKMARK",
            defaultVaultFolderName: defaultVaultFolderName,
            localVaultFolderName: defaultVaultFolderName,
            defaultLocation: .iCloud,
            iCloudContainerIdentifier: iCloudContainerIdentifier,
            deleteBudgetFile: { url in
                try FileManager.default.removeItem(at: url)
            }
        )
    }

    private(set) var budgets: [BWBudget] = []
    private(set) var vaultLocation: BWVaultLocation = .iCloud
    private(set) var vaultURL: URL?
    private(set) var skippedFiles: [String] = []

    @ObservationIgnored private var autoRefreshMonitor: BWBudgetFileChangeMonitor?
    @ObservationIgnored private var autoRefreshSnapshot: BWBudgetFileSnapshot?
    @ObservationIgnored private var autoRefreshBlockers: Set<String> = []
    @ObservationIgnored private var autoRefreshMutationCount = 0
    @ObservationIgnored private var isRefreshingFromDisk = false
    @ObservationIgnored private var hasPendingAutoRefresh = false

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

    deinit {
        autoRefreshMonitor?.stop()
    }

    static func resetUITestVaultState() {
        BWVault.resetStoredState(configuration: vaultConfiguration)

        do {
            let testVaultURL = try BWVault.defaultLocalVaultURL(configuration: vaultConfiguration)

            if FileManager.default.fileExists(atPath: testVaultURL.path) {
                try FileManager.default.removeItem(at: testVaultURL)
            }
        }
        catch {
            // UI tests will surface vault setup failures during app launch.
        }
    }

    func setAutoRefreshActive(_ isActive: Bool) {
        if isActive {
            startAutoRefreshLoop()
        }
        else {
            stopAutoRefreshLoop()
        }
    }

    func setAutoRefreshSuspended(_ isSuspended: Bool, reason: String) {
        if isSuspended {
            autoRefreshBlockers.insert(reason)
        }
        else {
            autoRefreshBlockers.remove(reason)
        }

        if autoRefreshBlockers.isEmpty {
            Task { [weak self] in
                await self?.drainPendingAutoRefreshIfNeeded()
            }
        }
    }

    private func startAutoRefreshLoop() {
        guard autoRefreshMonitor == nil else {
            return
        }

        autoRefreshMonitor = BWBudgetFileChangeMonitor { [weak self] in
            Task { @MainActor in
                await self?.handleAutoRefreshChange()
            }
        }

        Task { [weak self] in
            await self?.refreshFromDiskIfIdle()
            await self?.updateAutoRefreshPresentedItems()
        }
    }

    private func stopAutoRefreshLoop() {
        autoRefreshMonitor?.stop()
        autoRefreshMonitor = nil
        hasPendingAutoRefresh = false
    }

    private func withAutoRefreshPaused<T>(_ operation: () async -> T) async -> T {
        autoRefreshMutationCount += 1

        let result = await operation()

        autoRefreshMutationCount -= 1
        await drainPendingAutoRefreshIfNeeded()

        return result
    }

    private func updateAutoRefreshSnapshot() async {
        switch await BWBudgetService.refreshSnapshot(for: budgets, vault: vault) {
            case .failure:
                autoRefreshSnapshot = nil
            case .success(let snapshot):
                autoRefreshSnapshot = snapshot.openFiles
        }

        await updateAutoRefreshPresentedItems()
    }

    private func updateAutoRefreshPresentedItems() async {
        guard let autoRefreshMonitor else {
            return
        }

        let vaultURL = await vault.currentURL()
        let budgetURLs = budgets.compactMap { $0.url }

        autoRefreshMonitor.updatePresentedItems(
            vaultURL: vaultURL,
            budgetURLs: budgetURLs
        )
    }

    private func handleAutoRefreshChange() async {
        hasPendingAutoRefresh = true
        await drainPendingAutoRefreshIfNeeded()
    }

    private func drainPendingAutoRefreshIfNeeded() async {
        guard hasPendingAutoRefresh else {
            return
        }

        guard await refreshFromDiskIfIdle() else {
            return
        }

        hasPendingAutoRefresh = false
    }

    @discardableResult
    private func refreshFromDiskIfIdle() async -> Bool {
        guard !isLoadingBudgets,
              autoRefreshMutationCount == 0,
              autoRefreshBlockers.isEmpty,
              !isRefreshingFromDisk
        else {
            return false
        }

        isRefreshingFromDisk = true

        defer {
            isRefreshingFromDisk = false
        }

        switch await BWBudgetService.refreshSnapshot(for: budgets, vault: vault) {
            case .failure:
                return true
            case .success(let snapshot):
                guard let autoRefreshSnapshot else {
                    self.autoRefreshSnapshot = snapshot.openFiles
                    await updateAutoRefreshPresentedItems()
                    return true
                }

                guard autoRefreshSnapshot != snapshot.openFiles else {
                    await updateAutoRefreshPresentedItems()
                    return true
                }

                await reloadBudgetsForAutoRefresh(snapshot: snapshot)
                self.autoRefreshSnapshot = snapshot.openFiles
                await updateAutoRefreshPresentedItems()
                return true
        }
    }

    private func reloadBudgetsForAutoRefresh(snapshot: BWBudgetRefreshSnapshot) async {
        let previousSelectedBudgetID = self.selectedBudgetID
        let externalURLs = BWBudgetService.externalBudgetURLs(
            in: budgets,
            vaultSnapshot: snapshot.vault
        )
        var refreshedBudgets: [BWBudget]

        switch await BWBudgetService.loadBudgets(vault: vault) {
            case .failure:
                return
            case .success(let result):
                refreshedBudgets = result.budgets
                skippedFiles = result.skippedFiles
        }

        for url in externalURLs {
            switch await BWBudgetService.openBudget(at: url, vault: vault) {
                case .failure:
                    continue
                case .success(let result):
                    upsertBudget(result.budget, in: &refreshedBudgets)
            }
        }

        budgets = refreshedBudgets

        if let previousSelectedBudgetID,
           budget(withID: previousSelectedBudgetID) != nil {
            self.selectedBudgetID = previousSelectedBudgetID
        }
        else {
            restoreSelection()
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

        return await withAutoRefreshPaused {
            let result = await BWBudgetService.createCategory(
                in: budget,
                title: title,
                plannedAmount: plannedAmount,
                categoryType: categoryType,
                vault: vault
            )

            return await handleBudgetMutation(result)
        }
    }

    func updateBudgetTitle(_ title: String, for budgetID: UUID) async -> Bool {
        guard let budget = budget(withID: budgetID) else {
            return false
        }

        return await withAutoRefreshPaused {
            let result = await BWBudgetService.updateBudgetTitle(
                in: budget,
                title: title,
                vault: vault
            )

            return await handleBudgetMutation(result)
        }
    }

    func updateCategory(_ updatedCategory: BWCategory, in budgetID: UUID) async -> Bool {
        guard let budget = budget(withID: budgetID) else {
            return false
        }

        return await withAutoRefreshPaused {
            let result = await BWBudgetService.updateCategory(
                in: budget,
                category: updatedCategory,
                vault: vault
            )

            return await handleBudgetMutation(result)
        }
    }

    func deleteCategory(_ category: BWCategory, in budgetID: UUID) async {
        guard let budget = budget(withID: budgetID) else {
            return
        }

        await withAutoRefreshPaused {
            let result = await BWBudgetService.deleteCategory(
                in: budget,
                categoryID: category.id,
                vault: vault
            )

            _ = await handleBudgetMutation(result)
        }
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

        return await withAutoRefreshPaused {
            let result = await BWBudgetService.moveCategories(
                in: budget,
                for: categoryType,
                fromOffsets: sourceOffsets,
                toOffset: destination,
                vault: vault
            )

            return await handleBudgetMutation(result)
        }
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

        return await withAutoRefreshPaused {
            let result = await BWBudgetService.createTransaction(
                in: budget,
                categoryID: categoryID,
                title: title,
                description: description,
                date: date,
                amount: amount,
                vault: vault
            )

            return await handleBudgetMutation(result)
        }
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

        return await withAutoRefreshPaused {
            let result = await BWBudgetService.updateTransaction(
                in: budget,
                transaction: transaction,
                from: sourceCategoryID,
                to: destinationCategoryID,
                vault: vault
            )

            return await handleBudgetMutation(result)
        }
    }

    func deleteTransaction(
        _ transaction: BWTransaction,
        in budgetID: UUID,
        from categoryID: UUID
    ) async {
        guard let budget = budget(withID: budgetID) else {
            return
        }

        await withAutoRefreshPaused {
            let result = await BWBudgetService.deleteTransaction(
                in: budget,
                transactionID: transaction.id,
                from: categoryID,
                vault: vault
            )

            _ = await handleBudgetMutation(result)
        }
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

        switch await BWBudgetService.loadBudgets(vault: vault) {
            case .failure(let error):
                budgets = []
                selectedBudgetID = nil
                errorMessage = error.localizedDescription
            case .success(let result):
                budgets = result.budgets
                skippedFiles = result.skippedFiles
                restoreSelection()
                await updateAutoRefreshSnapshot()
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

    func openBudget(at url: URL) async {
        await withAutoRefreshPaused {
            switch await BWBudgetService.openBudget(at: url, vault: vault) {
                case .failure(let error):
                    errorMessage = error.localizedDescription
                case .success(let result):
                    if let vaultReadResult = result.vaultReadResult {
                        budgets = vaultReadResult.budgets
                        skippedFiles = vaultReadResult.skippedFiles
                    }

                    open(result.budget)
                    await updateAutoRefreshSnapshot()
            }
        }
    }

    func createBudget(title: String, template: BWTemplateSelection) async -> Bool {
        await withAutoRefreshPaused {
            switch await BWBudgetService.createBudget(
                title: title,
                template: template,
                budgetsInVault: budgets,
                vault: vault
            ) {
                case .failure(let error):
                    errorMessage = error.localizedDescription
                    return false
                case .success(let budget):
                    open(budget)
                    await loadBudgets()
                    selectBudget(withID: budget.id)
                    await updateAutoRefreshSnapshot()
                    return true
            }
        }
    }

    func deleteBudget(_ budget: BWBudget) async {
        await withAutoRefreshPaused {
            switch await BWBudgetService.deleteBudget(budget, vault: vault) {
                case .failure(let error):
                    errorMessage = error.localizedDescription
                case .success:
                    budgets.removeAll { $0.id == budget.id }
                    clearSelectionIfNeeded(deletedBudgetID: budget.id)
                    await updateAutoRefreshSnapshot()
            }
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
        await withAutoRefreshPaused {
            switch await vault.setLocation(location) {
                case .failure(let error):
                    errorMessage = error.localizedDescription
                case .success:
                    await loadBudgets()
            }

            await refreshVaultState()
        }
    }

    func setLocalVaultFolder(_ url: URL) async {
        await withAutoRefreshPaused {
            switch await vault.setLocalVaultFolder(url) {
                case .failure(let error):
                    errorMessage = error.localizedDescription
                case .success:
                    await loadBudgets()
            }

            await refreshVaultState()
        }
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

    private func handleBudgetMutation(_ result: Result<BWBudget, BWError>) async -> Bool {
        switch result {
            case .failure(.validation):
                return false
            case .failure(let error):
                errorMessage = error.localizedDescription
                return false
            case .success(let budget):
                upsertBudget(budget)
                await updateAutoRefreshSnapshot()
                return true
        }
    }

    private func upsertBudget(_ budget: BWBudget) {
        upsertBudget(budget, in: &budgets)
    }

    private func upsertBudget(_ budget: BWBudget, in budgets: inout [BWBudget]) {
        if let index = budgets.firstIndex(where: { $0.id == budget.id }) {
            budgets[index] = budget
        }
        else {
            budgets.append(budget)
        }
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
