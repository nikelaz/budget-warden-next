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
import CloudKit
import Foundation
import Observation

private actor BWBudgetMutationGate {
    private var isRunning = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if !isRunning {
            isRunning = true
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func signal() {
        guard !waiters.isEmpty else {
            isRunning = false
            return
        }

        waiters.removeFirst().resume()
    }
}

@MainActor
@Observable
final class BWStore {
    private let lastOpenedBudgetIDKey = "BWI_LAST_OPENED_BUDGET_ID"
    private let currencyKey = "BWI_CURRENCY"
    private static let iCloudContainerIdentifier = "iCloud.com.lazarovco.BudgetWarden"
    private static let defaultVaultFolderName = "Budget Warden Vaults"
    private static let iCloudEnabledKey = "BWI_ICLOUD_SYNC_ENABLED"
    private static let cloudSyncInterval: TimeInterval = 10
    private static let googleDrivePollingInterval = Duration.seconds(5)
    private static let googleDriveMetadataKey = "BWI_GOOGLE_DRIVE_METADATA_V1"

    let vault = BWVault(configuration: BWStore.vaultConfiguration, location: .local)
    let cloudVault = BWVault(configuration: BWStore.vaultConfiguration, location: .iCloud)
    let googleDriveVault = BWVault(configuration: BWStore.vaultConfiguration, location: .googleDrive)
    let cloudRepository = BWCloudBudgetRepository()
    let googleDriveSession = BWGoogleDriveSession()
    @ObservationIgnored lazy var googleDriveRepository = BWGoogleDriveRepository(
        vault: googleDriveVault,
        metadataKey: Self.googleDriveMetadataKey
    )

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

    private static var initialICloudEnabled: Bool {
        let defaults = UserDefaults.standard

        if defaults.object(forKey: iCloudEnabledKey) != nil {
            return defaults.bool(forKey: iCloudEnabledKey)
        }

        if defaults.string(forKey: "BWI_VAULT_LOCATION") == BWVaultLocation.iCloud.rawValue {
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

    private(set) var localBudgets: [BWBudget] = []
    private(set) var iCloudBudgets: [BWBudget] = []
    private(set) var googleDriveBudgets: [BWBudget] = []
    private(set) var vaultURL: URL?
    private(set) var skippedFiles: [String] = []
    private(set) var sharedBudgetIDs: Set<UUID> = []
    private(set) var googleDriveSharedBudgetIDs: Set<UUID> = []
    private(set) var isICloudEnabled: Bool

    var budgets: [BWBudget] {
        iCloudBudgets + googleDriveBudgets + localBudgets
    }

    @ObservationIgnored private var autoRefreshMonitor: BWBudgetFileChangeMonitor?
    @ObservationIgnored private var autoRefreshSnapshot: BWBudgetFileSnapshot?
    @ObservationIgnored private var autoRefreshBlockers: Set<String> = []
    @ObservationIgnored private var autoRefreshMutationCount = 0
    @ObservationIgnored private var isRefreshingFromDisk = false
    @ObservationIgnored private var lastCloudSyncDate: Date?
    @ObservationIgnored private var lastGoogleDriveSyncDate: Date?
    @ObservationIgnored private var isCloudSyncing = false
    @ObservationIgnored private var cloudUploadTask: Task<Void, Never>?
    @ObservationIgnored private var googleDriveUploadTask: Task<Void, Never>?
    @ObservationIgnored private var googleDrivePollingTask: Task<Void, Never>?
    @ObservationIgnored private var isGoogleDriveSyncing = false
    @ObservationIgnored private var hasPendingAutoRefresh = false
    @ObservationIgnored private let budgetMutationGate = BWBudgetMutationGate()

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
        isICloudEnabled = Self.initialICloudEnabled
    }

    deinit {
        autoRefreshMonitor?.stop()
        googleDrivePollingTask?.cancel()
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

    func isGoogleDriveBudget(_ budget: BWBudget) -> Bool {
        guard let budgetURL = budget.url?.standardizedFileURL else {
            return false
        }

        return googleDriveBudgets.contains {
            $0.url?.standardizedFileURL == budgetURL
        }
    }

    private func storageVault(for budget: BWBudget) -> BWVault {
        if isGoogleDriveBudget(budget) {
            return googleDriveVault
        }
        return isICloudBudget(budget) ? cloudVault : vault
    }

    @discardableResult
    func connectGoogleDrive() async -> Bool {
        do {
            try await googleDriveSession.connect()
            await synchronizeGoogleDriveBudgets()
            await updateAutoRefreshSnapshot()
            return true
        }
        catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func disconnectGoogleDrive() {
        googleDriveSession.disconnect()
        googleDriveBudgets = []
        googleDriveSharedBudgetIDs = []
        restoreSelection()
    }

    @discardableResult
    func enableICloud() async -> Bool {
        guard await cloudRepository.accountIsAvailable() else {
            errorMessage = BWError.iCloudUnavailable().localizedDescription
            return false
        }

        isICloudEnabled = true
        errorMessage = nil
        UserDefaults.standard.set(true, forKey: Self.iCloudEnabledKey)
        await synchronizeCloudBudgets()
        await updateAutoRefreshSnapshot()
        return true
    }

    static func resetUITestVaultState() {
        BWVault.resetStoredState(configuration: vaultConfiguration)
        UserDefaults.standard.removeObject(forKey: iCloudEnabledKey)

        do {
            let testVaultURL = try BWVault.defaultLocalVaultURL(configuration: vaultConfiguration)
            let cloudKitCacheURL = try BWVault.defaultCloudKitCacheURL(configuration: vaultConfiguration)
            let googleDriveCacheURL = try BWVault.defaultGoogleDriveCacheURL(configuration: vaultConfiguration)

            if FileManager.default.fileExists(atPath: testVaultURL.path) {
                try FileManager.default.removeItem(at: testVaultURL)
            }

            if FileManager.default.fileExists(atPath: cloudKitCacheURL.path) {
                try FileManager.default.removeItem(at: cloudKitCacheURL)
            }

            if FileManager.default.fileExists(atPath: googleDriveCacheURL.path) {
                try FileManager.default.removeItem(at: googleDriveCacheURL)
            }

            UserDefaults.standard.removeObject(forKey: googleDriveMetadataKey)
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
        startGoogleDrivePolling()

        Task { [weak self] in
            await self?.refreshFromDiskIfIdle()
            await self?.updateAutoRefreshPresentedItems()
        }
    }

    private func stopAutoRefreshLoop() {
        autoRefreshMonitor?.stop()
        autoRefreshMonitor = nil
        googleDrivePollingTask?.cancel()
        googleDrivePollingTask = nil
        hasPendingAutoRefresh = false
    }

    private func startGoogleDrivePolling() {
        guard googleDrivePollingTask == nil else { return }

        googleDrivePollingTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: Self.googleDrivePollingInterval)
                }
                catch {
                    return
                }

                guard let self else { return }
                await self.pollGoogleDriveIfIdle()
            }
        }
    }

    private func pollGoogleDriveIfIdle() async {
        guard googleDriveSession.isConnected,
              !isLoadingBudgets,
              autoRefreshMutationCount == 0,
              autoRefreshBlockers.isEmpty,
              !isRefreshingFromDisk
        else {
            return
        }

        await synchronizeGoogleDriveBudgets()
        await updateAutoRefreshSnapshot()
    }

    private func withAutoRefreshPaused<T>(_ operation: () async -> T) async -> T {
        autoRefreshMutationCount += 1

        let result = await operation()

        autoRefreshMutationCount -= 1
        await drainPendingAutoRefreshIfNeeded()

        return result
    }

    private func withBudgetMutation<T>(_ operation: () async -> T) async -> T {
        await budgetMutationGate.wait()

        let result = await withAutoRefreshPaused {
            await operation()
        }

        await budgetMutationGate.signal()
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

        if isICloudEnabled,
           lastCloudSyncDate.map({ Date().timeIntervalSince($0) >= Self.cloudSyncInterval }) ?? true {
            await synchronizeCloudBudgets()
        }

        if googleDriveSession.isConnected,
           lastGoogleDriveSyncDate.map({ Date().timeIntervalSince($0) >= Self.cloudSyncInterval }) ?? true {
            await synchronizeGoogleDriveBudgets()
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

        guard await reloadStoredBudgets() else {
            return
        }

        let storedPaths = Set(budgets.compactMap { $0.url?.standardizedFileURL.path })

        for url in externalURLs where !storedPaths.contains(url.standardizedFileURL.path) {
            switch await BWBudgetService.openBudget(at: url, vault: vault) {
                case .failure:
                    continue
                case .success(let result):
                    upsertBudget(result.budget, location: .local)
            }
        }

        if let previousSelectedBudgetID,
           budget(withID: previousSelectedBudgetID) != nil {
            self.selectedBudgetID = previousSelectedBudgetID
        }
        else {
            restoreSelection()
        }
    }

    @discardableResult
    private func reloadStoredBudgets() async -> Bool {
        let localResult = await BWBudgetService.loadBudgets(vault: vault)
        let cloudResult = await BWBudgetService.loadBudgets(vault: cloudVault)
        let googleDriveResult = await BWBudgetService.loadBudgets(vault: googleDriveVault)
        var loadedSkippedFiles: [String] = []
        var didLoadStorage = false

        switch localResult {
            case .failure:
                localBudgets = []
            case .success(let result):
                localBudgets = result.budgets
                loadedSkippedFiles.append(contentsOf: result.skippedFiles)
                didLoadStorage = true
        }

        switch cloudResult {
            case .failure:
                iCloudBudgets = []
            case .success(let result):
                iCloudBudgets = result.budgets
                loadedSkippedFiles.append(contentsOf: result.skippedFiles)
                didLoadStorage = true
        }

        switch googleDriveResult {
            case .failure:
                googleDriveBudgets = []
            case .success(let result):
                googleDriveBudgets = result.budgets
                loadedSkippedFiles.append(contentsOf: result.skippedFiles)
                didLoadStorage = true
        }

        skippedFiles = loadedSkippedFiles
        return didLoadStorage
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
        return await withBudgetMutation {
            guard let budget = budget(withID: budgetID) else {
                return false
            }

            let result = await BWBudgetService.createCategory(
                in: budget,
                title: title,
                plannedAmount: plannedAmount,
                categoryType: categoryType,
                vault: storageVault(for: budget)
            )

            return await handleBudgetMutation(result)
        }
    }

    func updateBudgetTitle(_ title: String, for budgetID: UUID) async -> Bool {
        return await withBudgetMutation {
            guard let budget = budget(withID: budgetID) else {
                return false
            }

            let result = await BWBudgetService.updateBudgetTitle(
                in: budget,
                title: title,
                vault: storageVault(for: budget)
            )

            return await handleBudgetMutation(result)
        }
    }

    func updateCategory(_ updatedCategory: BWCategory, in budgetID: UUID) async -> Bool {
        return await withBudgetMutation {
            guard let budget = budget(withID: budgetID) else {
                return false
            }

            let result = await BWBudgetService.updateCategory(
                in: budget,
                category: updatedCategory,
                vault: storageVault(for: budget)
            )

            return await handleBudgetMutation(result)
        }
    }

    func deleteCategory(_ category: BWCategory, in budgetID: UUID) async {
        await withBudgetMutation {
            guard let budget = budget(withID: budgetID) else {
                return
            }

            let result = await BWBudgetService.deleteCategory(
                in: budget,
                categoryID: category.id,
                vault: storageVault(for: budget)
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
        return await withBudgetMutation {
            guard let budget = budget(withID: budgetID) else {
                return false
            }

            let result = await BWBudgetService.moveCategories(
                in: budget,
                for: categoryType,
                fromOffsets: sourceOffsets,
                toOffset: destination,
                vault: storageVault(for: budget)
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
        return await withBudgetMutation {
            guard let budget = budget(withID: budgetID) else {
                return false
            }

            let result = await BWBudgetService.createTransaction(
                in: budget,
                categoryID: categoryID,
                title: title,
                description: description,
                date: date,
                amount: amount,
                vault: storageVault(for: budget)
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
        return await withBudgetMutation {
            guard let budget = budget(withID: budgetID) else {
                return false
            }

            let result = await BWBudgetService.updateTransaction(
                in: budget,
                transaction: transaction,
                from: sourceCategoryID,
                to: destinationCategoryID,
                vault: storageVault(for: budget)
            )

            return await handleBudgetMutation(result)
        }
    }

    func deleteTransaction(
        _ transaction: BWTransaction,
        in budgetID: UUID,
        from categoryID: UUID
    ) async {
        await withBudgetMutation {
            guard let budget = budget(withID: budgetID) else {
                return
            }

            let result = await BWBudgetService.deleteTransaction(
                in: budget,
                transactionID: transaction.id,
                from: categoryID,
                vault: storageVault(for: budget)
            )

            _ = await handleBudgetMutation(result)
        }
    }

    func refreshVaultState() async {
        vaultURL = await vault.currentURL()
    }

    func loadBudgets() async {
        isLoadingBudgets = true
        defer {
            isLoadingBudgets = false
        }

        await refreshVaultState()

        guard await reloadStoredBudgets() else {
            selectedBudgetID = nil
            errorMessage = BWError.vaultNotSet().localizedDescription
            return
        }

        restoreSelection()
        await updateAutoRefreshSnapshot()
        scheduleCloudSynchronization()
        Task { [weak self] in
            guard let self else { return }
            await self.googleDriveSession.restore()
            if self.googleDriveSession.isConnected {
                await self.synchronizeGoogleDriveBudgets()
                await self.updateAutoRefreshSnapshot()
            }
            else {
                self.googleDriveBudgets = []
                self.googleDriveSharedBudgetIDs = []
                self.restoreSelection()
            }
        }
    }

    func selectBudget(withID budgetID: UUID) {
        guard budget(withID: budgetID) != nil else {
            return
        }

        selectedBudgetID = budgetID
        UserDefaults.standard.set(budgetID.uuidString, forKey: lastOpenedBudgetIDKey)
    }

    func open(_ budget: BWBudget, location: BWVaultLocation? = nil) {
        upsertBudget(budget, location: location)
        selectBudget(withID: budget.id)
    }

    func openBudget(at url: URL) async {
        await withAutoRefreshPaused {
            let location: BWVaultLocation?
            let sourceVault: BWVault

            if await cloudVault.containsBudgetFile(url: url) {
                location = .iCloud
                sourceVault = cloudVault
            }
            else if await googleDriveVault.containsBudgetFile(url: url) {
                location = .googleDrive
                sourceVault = googleDriveVault
            }
            else if await vault.containsBudgetFile(url: url) {
                location = .local
                sourceVault = vault
            }
            else {
                location = nil
                sourceVault = vault
            }

            switch await BWBudgetService.openBudget(at: url, vault: sourceVault) {
                case .failure(let error):
                    errorMessage = error.localizedDescription
                case .success(let result):
                    if let vaultReadResult = result.vaultReadResult,
                       let location {
                        switch location {
                            case .iCloud:
                                iCloudBudgets = vaultReadResult.budgets
                            case .googleDrive:
                                googleDriveBudgets = vaultReadResult.budgets
                            case .local:
                                localBudgets = vaultReadResult.budgets
                        }
                        skippedFiles = vaultReadResult.skippedFiles
                    }

                    open(result.budget, location: location ?? .local)
                    await updateAutoRefreshSnapshot()
            }
        }
    }

    func createBudget(
        title: String,
        template: BWTemplateSelection,
        location: BWVaultLocation
    ) async -> Bool {
        if location == .iCloud, !isICloudEnabled,
           !(await enableICloud()) {
            return false
        }

        if location == .googleDrive, !googleDriveSession.isConnected,
           !(await connectGoogleDrive()) {
            return false
        }

        let destinationVault: BWVault
        switch location {
            case .iCloud:
                destinationVault = cloudVault
            case .googleDrive:
                destinationVault = googleDriveVault
            case .local:
                destinationVault = vault
        }

        return await withBudgetMutation {
            switch await BWBudgetService.createBudget(
                title: title,
                template: template,
                budgetsInVault: budgets,
                vault: destinationVault
            ) {
                case .failure(let error):
                    errorMessage = error.localizedDescription
                    return false
                case .success(let budget):
                    open(budget, location: location)
                    scheduleCloudSave(budget)
                    scheduleGoogleDriveSave(budget)
                    await updateAutoRefreshSnapshot()
                    return true
            }
        }
    }

    func deleteBudget(_ budget: BWBudget) async {
        await withBudgetMutation {
            let isCloudBudget = isICloudBudget(budget)
            let isDriveBudget = isGoogleDriveBudget(budget)
            let sourceVault = isDriveBudget ? googleDriveVault : (isCloudBudget ? cloudVault : vault)

            if isCloudBudget,
               case .failure(let error) = await cloudRepository.delete(budget.id) {
                errorMessage = error.localizedDescription
                return
            }

            if isDriveBudget {
                do {
                    let token = try await googleDriveSession.accessToken()
                    if case .failure(let error) = await googleDriveRepository.delete(
                        budget,
                        accessToken: token
                    ) {
                        errorMessage = error.localizedDescription
                        return
                    }
                }
                catch {
                    errorMessage = error.localizedDescription
                    return
                }
            }

            switch await BWBudgetService.deleteBudget(budget, vault: sourceVault) {
                case .failure(let error):
                    errorMessage = error.localizedDescription
                case .success:
                    if isCloudBudget {
                        iCloudBudgets.removeAll { $0.id == budget.id }
                    }
                    else if isDriveBudget {
                        googleDriveBudgets.removeAll { $0.id == budget.id }
                        googleDriveSharedBudgetIDs.remove(budget.id)
                    }
                    else {
                        localBudgets.removeAll { $0.id == budget.id }
                    }
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
                scheduleCloudSave(budget)
                scheduleGoogleDriveSave(budget)
                await updateAutoRefreshSnapshot()
                return true
        }
    }

    private func synchronizeCloudBudgets() async {
        guard isICloudEnabled else {
            sharedBudgetIDs = []
            return
        }

        guard !isCloudSyncing else {
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
                    skippedFiles = result.skippedFiles
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
            errorMessage = "Enable iCloud in Storage settings, then open the sharing link again."
            return false
        }

        for attempt in 0..<10 {
            if case .success(let cloudBudget) = await cloudRepository.fetchSharedBudget(
                recordID: recordID
            ),
            case .success(let cachedBudget) = await cloudVault.cacheCloudBudget(cloudBudget.budget) {
                sharedBudgetIDs.insert(cachedBudget.id)
                open(cachedBudget, location: .iCloud)
                errorMessage = nil
                await updateAutoRefreshSnapshot()
                scheduleCloudSynchronization()
                return true
            }

            if attempt < 9 {
                let retryDelay = min(250 * (attempt + 1), 1_000)
                try? await Task.sleep(for: .milliseconds(retryDelay))
            }
        }

        errorMessage = "The shared budget was accepted, but it could not be downloaded from iCloud yet. Make sure both apps use the same CloudKit environment, then open the sharing link again."
        return false
    }

    private func scheduleCloudSave(_ budget: BWBudget) {
        let previousUpload = cloudUploadTask

        cloudUploadTask = Task { [weak self] in
            await previousUpload?.value

            guard let self,
                  self.isICloudEnabled,
                  self.isICloudBudget(budget)
            else {
                return
            }

            if case .failure(let error) = await self.cloudRepository.save(budget) {
                self.errorMessage = error.localizedDescription
            }
        }
    }

    private func synchronizeGoogleDriveBudgets() async {
        guard googleDriveSession.isConnected, !isGoogleDriveSyncing else {
            return
        }

        isGoogleDriveSyncing = true
        defer { isGoogleDriveSyncing = false }

        do {
            let token = try await googleDriveSession.accessToken()
            switch await googleDriveRepository.synchronize(accessToken: token) {
                case .failure:
                    // Keep the local Drive cache available while offline.
                    return
                case .success(let driveBudgets):
                    lastGoogleDriveSyncDate = Date()
                    googleDriveSharedBudgetIDs = Set(driveBudgets.lazy
                        .filter(\.isSharedWithCurrentUser)
                        .map { $0.budget.id })
                    if case .success(let result) = await BWBudgetService.loadBudgets(
                        vault: googleDriveVault
                    ) {
                        googleDriveBudgets = result.budgets
                    }
            }
        }
        catch {
            // Token refresh and network failures leave the cache usable.
        }
    }

    private func scheduleGoogleDriveSave(_ budget: BWBudget) {
        guard isGoogleDriveBudget(budget) else { return }
        let previousUpload = googleDriveUploadTask

        googleDriveUploadTask = Task { [weak self] in
            await previousUpload?.value
            guard let self, self.googleDriveSession.isConnected else { return }

            do {
                let token = try await self.googleDriveSession.accessToken()
                switch await self.googleDriveRepository.save(budget, accessToken: token) {
                    case .failure(let error):
                        self.errorMessage = error.localizedDescription
                    case .success(let merged):
                        self.upsertBudget(merged, location: .googleDrive)
                }
            }
            catch {
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func shareGoogleDriveBudget(_ budget: BWBudget, with email: String) async -> Bool {
        guard isGoogleDriveBudget(budget) else { return false }

        do {
            let token = try await googleDriveSession.accessToken()
            switch await googleDriveRepository.share(budget, with: email, accessToken: token) {
                case .failure(let error):
                    errorMessage = error.localizedDescription
                    return false
                case .success:
                    return true
            }
        }
        catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func upsertBudget(
        _ budget: BWBudget,
        location: BWVaultLocation? = nil
    ) {
        let location = location
            ?? (isGoogleDriveBudget(budget) ? .googleDrive : (isICloudBudget(budget) ? .iCloud : .local))

        switch location {
            case .iCloud:
                upsertBudget(budget, in: &iCloudBudgets)
            case .googleDrive:
                upsertBudget(budget, in: &googleDriveBudgets)
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
