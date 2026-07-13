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
import CloudKit
import UniformTypeIdentifiers
import BudgetWardenAppleCore

@MainActor
class BWStore: ObservableObject {
    private let currencyKey = "BW_CURRENCY"
    private static let iCloudContainerIdentifier = "iCloud.com.lazarovco.BudgetWarden"
    private static let defaultVaultFolderName = "Budget Warden Vaults"
    private static let iCloudEnabledKey = "BW_ICLOUD_SYNC_ENABLED"
    private static let cloudSyncInterval: TimeInterval = 10

    @Published var currentBudget: BWBudget? = nil
    @Published private(set) var localBudgets: [BWBudget] = []
    @Published private(set) var iCloudBudgets: [BWBudget] = []
    @Published var budgetsInVaultLoaded: Bool = false
    @Published var isVaultNotSet: Bool = false
    @Published var vaultWarningMessage: String? = nil
    @Published private(set) var sharedBudgetIDs: Set<UUID> = []
    @Published private(set) var isICloudEnabled: Bool

    var budgetsInVault: [BWBudget] {
        iCloudBudgets + localBudgets
    }

    let cloudRepository = BWCloudBudgetRepository()

    private var autoRefreshTask: Task<Void, Never>?
    private var autoRefreshSnapshot: BWBudgetFileSnapshot?
    private var autoRefreshBlockers: Set<String> = []
    private var autoRefreshMutationCount = 0
    private var isRefreshingFromDisk = false
    private var lastCloudSyncDate: Date?
    private var isCloudSyncing = false
    private var cloudUploadTask: Task<Void, Never>?

    // Currency
    @Published var selectedCurrency: BWCurrency {
        didSet {
            UserDefaults.standard.set(selectedCurrency.rawValue, forKey: currencyKey)
        }
    }

    let vault = BWVault(configuration: BWStore.vaultConfiguration, location: .local)
    let cloudVault = BWVault(configuration: BWStore.vaultConfiguration, location: .iCloud)

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

    private static var initialICloudEnabled: Bool {
        let defaults = UserDefaults.standard

        if defaults.object(forKey: iCloudEnabledKey) != nil {
            return defaults.bool(forKey: iCloudEnabledKey)
        }

        if defaults.string(forKey: "BW_VAULT_LOCATION") == BWVaultLocation.iCloud.rawValue {
            return true
        }

        guard let cacheURL = try? BWVault.defaultCloudKitCacheURL(configuration: vaultConfiguration),
              let files = try? FileManager.default.contentsOfDirectory(
                at: cacheURL,
                includingPropertiesForKeys: nil
              )
        else {
            return false
        }

        return files.contains { BWFiles.isBudgetFile($0) }
    }

    init() {
        let savedCurrency = UserDefaults.standard.string(forKey: currencyKey)
            .flatMap(BWCurrency.init(rawValue:))
        _selectedCurrency = Published(initialValue: savedCurrency ?? .defaultCurrency)
        _isICloudEnabled = Published(initialValue: Self.initialICloudEnabled)
    }

    deinit {
        autoRefreshTask?.cancel()
    }

    var preferredBudgetLocation: BWVaultLocation {
        isICloudEnabled ? .iCloud : .local
    }

    func isICloudBudget(_ budget: BWBudget) -> Bool {
        guard let budgetURL = budget.url?.standardizedFileURL else {
            return false
        }

        return iCloudBudgets.contains {
            $0.url?.standardizedFileURL == budgetURL
        }
    }

    private func storageVault(for budget: BWBudget) -> BWVault {
        isICloudBudget(budget) ? cloudVault : vault
    }

    @discardableResult
    func enableICloud() async -> BWError? {
        guard await cloudRepository.accountIsAvailable() else {
            return .iCloudUnavailable()
        }

        isICloudEnabled = true
        UserDefaults.standard.set(true, forKey: Self.iCloudEnabledKey)
        await synchronizeCloudBudgets()
        await updateAutoRefreshSnapshot()
        return nil
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
    }

    private func startAutoRefreshLoop() {
        guard autoRefreshTask == nil else {
            return
        }

        autoRefreshTask = Task { [weak self] in
            await self?.refreshFromDiskIfIdle()

            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(3))
                }
                catch {
                    break
                }

                await self?.refreshFromDiskIfIdle()
            }
        }
    }

    private func stopAutoRefreshLoop() {
        autoRefreshTask?.cancel()
        autoRefreshTask = nil
    }

    private func withAutoRefreshPaused<T>(_ operation: () async -> T) async -> T {
        autoRefreshMutationCount += 1

        defer {
            autoRefreshMutationCount -= 1
        }

        return await operation()
    }

    private func trackedBudgetsForAutoRefresh() -> [BWBudget] {
        guard let currentBudget,
              !budgetsInVault.contains(where: { $0.id == currentBudget.id })
        else {
            return budgetsInVault
        }

        return budgetsInVault + [currentBudget]
    }

    private func updateAutoRefreshSnapshot() async {
        switch await BWBudgetService.refreshSnapshot(
            for: trackedBudgetsForAutoRefresh(),
            vault: vault
        ) {
            case .failure:
                autoRefreshSnapshot = nil
            case .success(let snapshot):
                autoRefreshSnapshot = snapshot.openFiles
        }
    }

    private func refreshFromDiskIfIdle() async {
        guard budgetsInVaultLoaded,
              autoRefreshMutationCount == 0,
              autoRefreshBlockers.isEmpty,
              !isRefreshingFromDisk
        else {
            return
        }

        isRefreshingFromDisk = true

        defer {
            isRefreshingFromDisk = false
        }

        if isICloudEnabled,
           lastCloudSyncDate.map({ Date().timeIntervalSince($0) >= Self.cloudSyncInterval }) ?? true {
            await synchronizeCloudBudgets()
        }

        switch await BWBudgetService.refreshSnapshot(
            for: trackedBudgetsForAutoRefresh(),
            vault: vault
        ) {
            case .failure:
                return
            case .success(let snapshot):
                guard let autoRefreshSnapshot else {
                    self.autoRefreshSnapshot = snapshot.openFiles
                    return
                }

                guard autoRefreshSnapshot != snapshot.openFiles else {
                    return
                }

                await reloadBudgetsForAutoRefresh(snapshot: snapshot)
                self.autoRefreshSnapshot = snapshot.openFiles
        }
    }

    private func reloadBudgetsForAutoRefresh(snapshot: BWBudgetRefreshSnapshot) async {
        let previousCurrentBudget = currentBudget
        let externalURLs = BWBudgetService.externalBudgetURLs(
            in: trackedBudgetsForAutoRefresh(),
            vaultSnapshot: snapshot.vault
        )

        guard await reloadStoredBudgets() else {
            return
        }

        if let previousCurrentBudget,
           let refreshedCurrentBudget = refreshedBudget(matching: previousCurrentBudget) {
            currentBudget = refreshedCurrentBudget
            return
        }

        guard let currentBudgetURL = currentBudget?.url?.standardizedFileURL,
              externalURLs.contains(where: { $0.standardizedFileURL == currentBudgetURL })
        else {
            currentBudget = nil
            return
        }

        switch await BWBudgetService.openBudget(at: currentBudgetURL, vault: vault) {
            case .failure:
                currentBudget = nil
            case .success(let result):
                currentBudget = result.budget
        }
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

        let selectVaultRes = await withAutoRefreshPaused {
            await vault.setLocalVaultFolder(url)
        }
       
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

    @discardableResult
    private func reloadStoredBudgets() async -> Bool {
        let localResult = await BWBudgetService.loadBudgets(vault: vault)
        let cloudResult = await BWBudgetService.loadBudgets(vault: cloudVault)
        var skippedFiles: [String] = []
        var didLoadStorage = false

        switch localResult {
            case .failure:
                localBudgets = []
            case .success(let result):
                localBudgets = result.budgets
                skippedFiles.append(contentsOf: result.skippedFiles)
                didLoadStorage = true
        }

        switch cloudResult {
            case .failure:
                iCloudBudgets = []
            case .success(let result):
                iCloudBudgets = result.budgets
                skippedFiles.append(contentsOf: result.skippedFiles)
                didLoadStorage = true
        }

        setVaultWarning(skippedFiles: skippedFiles)
        return didLoadStorage
    }

    private func refreshedBudget(matching budget: BWBudget) -> BWBudget? {
        if let budgetURL = budget.url?.standardizedFileURL,
           let match = budgetsInVault.first(where: {
               $0.url?.standardizedFileURL == budgetURL
           }) {
            return match
        }

        return budgetsInVault.first(where: { $0.id == budget.id })
    }

    func loadBudgetsFromVault() async {
        localBudgets = []
        iCloudBudgets = []
        budgetsInVaultLoaded = false
        isVaultNotSet = false

        let previousCurrentBudget = currentBudget
        let didLoadStorage = await reloadStoredBudgets()
        isVaultNotSet = !didLoadStorage
        budgetsInVaultLoaded = true

        if let previousCurrentBudget,
           let refreshedCurrentBudget = refreshedBudget(matching: previousCurrentBudget) {
            currentBudget = refreshedCurrentBudget
        }

        await updateAutoRefreshSnapshot()
        scheduleCloudSynchronization()
    }

    func reloadBudgetsFromVault() async {
        let previousCurrentBudget = currentBudget

        guard await reloadStoredBudgets() else {
            return
        }

        if let previousCurrentBudget,
           let refreshedCurrentBudget = refreshedBudget(matching: previousCurrentBudget) {
            currentBudget = refreshedCurrentBudget
        }

        await updateAutoRefreshSnapshot()
    }

    func createBudget(
        title: String,
        template: BWTemplateSelection,
        location: BWVaultLocation,
        windowStore: BWWindowStore
    ) async -> Bool {
        if location == .iCloud, !isICloudEnabled,
           let error = await enableICloud() {
            windowStore.setError(error)
            return false
        }

        let destinationVault = location == .iCloud ? cloudVault : vault

        if location == .local, await destinationVault.currentURL() == nil {
            await selectVaultFolder()
        }

        return await withAutoRefreshPaused {
            let budgetCreationRes = await BWBudgetService.createBudget(
                title: title,
                template: template,
                budgetsInVault: budgetsInVault,
                vault: destinationVault
            )

            switch budgetCreationRes {
                case .failure(let error):
                    windowStore.closeBudgetDialog()
                    windowStore.setError(error)
                    return false
                case .success(let budget):
                    upsertBudgetInVaultList(budget, location: location)
                    selectBudget(budget)
                    scheduleCloudSave(budget, windowStore: windowStore)
                    await updateAutoRefreshSnapshot()
            }

            return true
        }
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

        return await withAutoRefreshPaused {
            let result = await BWBudgetService.createCategory(
                in: budget,
                title: title,
                plannedAmount: plannedAmount,
                categoryType: categoryType,
                vault: storageVault(for: budget)
            )

            return await handleBudgetMutation(
                result,
                windowStore: windowStore
            )
        }
    }

    func updateCategory(_ updatedCategory: BWCategory, windowStore: BWWindowStore) async -> Bool {
        guard let budget = currentBudget else {
            return false
        }

        return await withAutoRefreshPaused {
            let result = await BWBudgetService.updateCategory(
                in: budget,
                category: updatedCategory,
                vault: storageVault(for: budget)
            )

            return await handleBudgetMutation(
                result,
                windowStore: windowStore
            )
        }
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

        return await withAutoRefreshPaused {
            let result = await BWBudgetService.moveCategory(
                category,
                in: budget,
                by: offset,
                vault: storageVault(for: budget)
            )

            return await handleBudgetMutation(
                result,
                windowStore: windowStore
            )
        }
    }

    func deleteCategory(_ category: BWCategory, windowStore: BWWindowStore) async {
        guard let budget = currentBudget else {
            return
        }

        await withAutoRefreshPaused {
            let result = await BWBudgetService.deleteCategory(
                in: budget,
                categoryID: category.id,
                vault: storageVault(for: budget)
            )

            _ = await handleBudgetMutation(
                result,
                windowStore: windowStore
            )
        }
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

        return await withAutoRefreshPaused {
            let result = await BWBudgetService.createTransaction(
                in: budget,
                categoryID: categoryID,
                title: title,
                description: description,
                date: date,
                amount: amount,
                vault: storageVault(for: budget)
            )

            return await handleBudgetMutation(
                result,
                windowStore: windowStore
            )
        }
    }

    func updateTransaction(
        categoryID: UUID,
        transaction: BWTransaction,
        windowStore: BWWindowStore
    ) async -> Bool {
        guard let budget = currentBudget else {
            return false
        }

        return await withAutoRefreshPaused {
            let result = await BWBudgetService.updateTransaction(
                in: budget,
                transaction: transaction,
                from: categoryID,
                to: categoryID,
                vault: storageVault(for: budget)
            )

            return await handleBudgetMutation(
                result,
                windowStore: windowStore
            )
        }
    }

    func deleteTransaction(
        categoryID: UUID,
        transactionID: UUID,
        windowStore: BWWindowStore
    ) async {
        guard let budget = currentBudget else {
            return
        }

        await withAutoRefreshPaused {
            let result = await BWBudgetService.deleteTransaction(
                in: budget,
                transactionID: transactionID,
                from: categoryID,
                vault: storageVault(for: budget)
            )

            _ = await handleBudgetMutation(
                result,
                windowStore: windowStore
            )
        }
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

        return await withAutoRefreshPaused {
            let result = await BWBudgetService.updateTransaction(
                in: budget,
                transaction: transaction,
                from: sourceCategoryID,
                to: destinationCategoryID,
                vault: storageVault(for: budget)
            )

            return await handleBudgetMutation(
                result,
                windowStore: windowStore
            )
        }
    }

    private func handleBudgetMutation(
        _ result: Result<BWBudget, BWError>,
        windowStore: BWWindowStore
    ) async -> Bool {
        switch result {
            case .failure(.validation):
                return false
            case .failure(let error):
                windowStore.setError(error)
                return false
            case .success(let budget):
                currentBudget = budget
                upsertBudgetInVaultList(budget)
                scheduleCloudSave(budget, windowStore: windowStore)
                await updateAutoRefreshSnapshot()
                return true
        }
    }

    private func upsertBudgetInVaultList(
        _ budget: BWBudget,
        location: BWVaultLocation? = nil
    ) {
        let location = location ?? (isICloudBudget(budget) ? .iCloud : .local)

        switch location {
            case .iCloud:
                upsertBudget(budget, in: &iCloudBudgets)
            case .local:
                upsertBudget(budget, in: &localBudgets)
        }
    }

    private func upsertBudget(_ budget: BWBudget, in budgets: inout [BWBudget]) {
        if let index = budgets.firstIndex(where: { $0.id == budget.id }) {
            budgets[index] = budget
        }
        else {
            budgets.append(budget)
        }

        budgets.sort {
            $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    private func synchronizeCloudBudgets() async {
        guard isICloudEnabled else {
            sharedBudgetIDs = []
            return
        }

        if isCloudSyncing {
            while isCloudSyncing {
                try? await Task.sleep(for: .milliseconds(50))
            }
            return
        }

        isCloudSyncing = true

        defer {
            isCloudSyncing = false
        }

        if !(await cloudRepository.legacyICloudDriveMigrationIsComplete()) {
            switch await vault.readLegacyICloudBudgets() {
                case .failure:
                    return
                case .success(let legacyResult):
                    if case .failure = await cloudRepository.migrateLegacyICloudBudgets(
                        legacyResult.budgets
                    ) {
                        return
                    }
            }
        }

        switch await cloudRepository.synchronize(localBudgets: iCloudBudgets, vault: cloudVault) {
            case .failure:
                // The local CloudKit cache remains usable while offline.
                return
            case .success(let cloudBudgets):
                lastCloudSyncDate = Date()
                sharedBudgetIDs = Set(cloudBudgets.lazy
                    .filter(\.isSharedWithCurrentUser)
                    .map { $0.budget.id })

                if case .success(let result) = await BWBudgetService.loadBudgets(vault: cloudVault) {
                    iCloudBudgets = result.budgets
                    setVaultWarning(skippedFiles: result.skippedFiles)

                    if let currentBudget,
                       let refreshedCurrentBudget = refreshedBudget(matching: currentBudget),
                       isICloudBudget(refreshedCurrentBudget) {
                        self.currentBudget = refreshedCurrentBudget
                    }
                }
        }
    }

    private func scheduleCloudSynchronization() {
        Task { [weak self] in
            guard let self else {
                return
            }

            await self.synchronizeCloudBudgets()
            await self.updateAutoRefreshSnapshot()
        }
    }

    func openAcceptedCloudShare(recordID: CKRecord.ID) async -> Bool {
        guard isICloudEnabled else {
            vaultWarningMessage = "Enable iCloud in Storage settings, then open the sharing link again."
            return false
        }

        for attempt in 0..<10 {
            if case .success(let cloudBudget) = await cloudRepository.fetchSharedBudget(
                recordID: recordID
            ),
            case .success(let cachedBudget) = await cloudVault.cacheCloudBudget(cloudBudget.budget) {
                upsertBudgetInVaultList(cachedBudget, location: .iCloud)
                sharedBudgetIDs.insert(cachedBudget.id)
                selectBudget(cachedBudget)
                vaultWarningMessage = nil
                await updateAutoRefreshSnapshot()
                scheduleCloudSynchronization()
                return true
            }

            if attempt < 9 {
                let retryDelay = min(250 * (attempt + 1), 1_000)
                try? await Task.sleep(for: .milliseconds(retryDelay))
            }
        }

        vaultWarningMessage = "The shared budget was accepted, but it could not be downloaded from iCloud yet. Check your connection and open the sharing link again."
        return false
    }

    private func scheduleCloudSave(_ budget: BWBudget, windowStore: BWWindowStore) {
        let previousUpload = cloudUploadTask

        cloudUploadTask = Task { [weak self, weak windowStore] in
            await previousUpload?.value

            guard let self,
                  self.isICloudEnabled,
                  self.isICloudBudget(budget)
            else {
                return
            }

            if case .failure(let error) = await self.cloudRepository.save(budget) {
                windowStore?.setError(error)
            }
        }
    }

    func removeBudget(url: URL, windowStore: BWWindowStore) async {
        guard let budget = budgetsInVault.first(where: { $0.url == url }) else {
            let sourceVault: BWVault

            if await cloudVault.containsBudgetFile(url: url) {
                sourceVault = cloudVault
            }
            else {
                sourceVault = vault
            }

            let removeBudgetRes = await withAutoRefreshPaused {
                await sourceVault.removeBudgetFromVault(url: url)
            }

            switch removeBudgetRes {
                case .failure(let error):
                    windowStore.setError(error)
                    return
                case .success:
                    await reloadBudgetsFromVault()
                    return
            }
        }

        let isCloudBudget = isICloudBudget(budget)
        let sourceVault = isCloudBudget ? cloudVault : vault
        let removeBudgetRes = await withAutoRefreshPaused {
            if isCloudBudget,
               case .failure(let error) = await cloudRepository.delete(budget.id) {
                return Result<Void, BWError>.failure(error)
            }

            return await BWBudgetService.deleteBudget(
                budget,
                vault: sourceVault
            )
        }

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
        await withAutoRefreshPaused {
            let location: BWVaultLocation?
            let sourceVault: BWVault

            if await cloudVault.containsBudgetFile(url: url) {
                location = .iCloud
                sourceVault = cloudVault
            }
            else if await vault.containsBudgetFile(url: url) {
                location = .local
                sourceVault = vault
            }
            else {
                location = nil
                sourceVault = vault
            }

            let openBudgetRes = await BWBudgetService.openBudget(
                at: url,
                vault: sourceVault
            )

            switch openBudgetRes {
                case .failure(let error):
                    windowStore.setError(error)
                    return false
                case .success(let result):
                    if let vaultReadResult = result.vaultReadResult,
                       let location {
                        switch location {
                            case .iCloud:
                                iCloudBudgets = vaultReadResult.budgets
                            case .local:
                                localBudgets = vaultReadResult.budgets
                        }
                        setVaultWarning(skippedFiles: vaultReadResult.skippedFiles)
                    }

                    currentBudget = result.budget
                    await updateAutoRefreshSnapshot()
                    return true
            }
        }
    }
}
