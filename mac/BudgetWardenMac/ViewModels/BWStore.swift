/*
 * Budget Warden
 * Copyright (c) 2026 Lazarov & Co EOOD
 * Author: Nikola Lazarov
 *
 * Licensed under the Source-Available Educational License.
 * See the LICENSE file in the project root for full terms.
 */

import AppKit
import Combine
import Foundation
import AppIntents
import UniformTypeIdentifiers
import BWAppleCore

enum BWBudgetTemplateSelection: Hashable {
    case builtIn(String)
    case previousBudget(BWBudget)
}

/// Where a new budget is stored.
enum BWBudgetLocation: Hashable, CaseIterable {
    case thisMac
    case iCloud
    case googleDrive

    var title: String {
        switch self {
        case .thisMac: "This Mac"
        case .iCloud: "iCloud Drive"
        case .googleDrive: "Google Drive"
        }
    }
}

@MainActor
final class BWStore: ObservableObject {
    private static let recentBookmarksKey = "BW_RECENT_BUDGET_BOOKMARKS_V1"
    private static let currencyKey = "BW_CURRENCY"
    private static let deviceIDKey = "BW_DEVICE_ID"

    @Published var currentBudget: BWBudget? {
        didSet { shareBudgetsWithMcp() }
    }
    @Published var recentFiles: [URL] = NSDocumentController.shared.recentDocumentURLs {
        didSet {
            shareBudgetsWithMcp()
            iCloud.includeSharedBudgets(among: recentFiles)
        }
    }
    /// The currency for new budgets and for budgets saved before budgets
    /// stored one.
    @Published var defaultCurrency: BWCurrency {
        didSet {
            UserDefaults.standard.set(defaultCurrency.rawValue, forKey: Self.currencyKey)
            shareBudgetsWithMcp()
        }
    }

    /// The currency the open budget's amounts are shown in.
    var currency: BWCurrency {
        currentBudget.map(currency(of:)) ?? defaultCurrency
    }

    func currency(of budget: BWBudget) -> BWCurrency {
        budget.currency.flatMap(BWCurrency.init(rawValue:)) ?? defaultCurrency
    }
    @Published private(set) var mcpSettings: BWMcpSettings?
    @Published private(set) var mcpStatus: BWMcpServerStatus?
    @Published private(set) var mcpErrorMessage: String?
    /// Changes when an MCP client asks the app to show a budget.
    @Published private(set) var mcpShowBudgetRequest = UUID()

    private var mcpServer: BWMcpServerController?
    /// The budgets the MCP server and Shortcuts can read and change.
    let library: BWBudgetLibrary

    /// Budgets in Google Drive, including ones shared with the user.
    let googleDrive: BWGoogleDriveController
    /// Budgets in iCloud Drive.
    let iCloud: BWICloudBudgetLibrary
    private let cloudChanges: BWBudgetChangeRelay
    private var cloudSyncTimer: AnyCancellable?

    private var currentSecurityScopedURL: URL?
    var hasAttemptedLegacyMigration = false

    init() {
        let cloudChanges = BWBudgetChangeRelay()
        self.cloudChanges = cloudChanges
        let libraryEvents = BWBudgetLibraryEventRelay()
        library = BWBudgetLibrary(
            newBudgetDirectory: { BWStore.mcpBudgetDirectory() },
            events: { event in libraryEvents.handler?(event) }
        )
        googleDrive = BWGoogleDriveController { url in cloudChanges.notify(url) }
        iCloud = BWICloudBudgetLibrary { url in cloudChanges.notify(url) }

        let defaults = UserDefaults.standard
        defaultCurrency = defaults.string(forKey: Self.currencyKey)
            .flatMap(BWCurrency.init(rawValue:)) ?? .defaultCurrency

        let deviceID: UUID
        if let saved = defaults.string(forKey: Self.deviceIDKey).flatMap(UUID.init(uuidString:)) {
            deviceID = saved
        } else {
            deviceID = UUID()
            defaults.set(deviceID.uuidString, forKey: Self.deviceIDKey)
        }

        do {
            try initializeCore(deviceId: deviceID)
        } catch let error as FfiError where error.message != "Rust core is already initialized" {
            assertionFailure("Could not initialize BWCore: \(error.message)")
        } catch {
            assertionFailure("Could not initialize BWCore: \(error.localizedDescription)")
        }

        mcpServer = BWMcpServerController(
            keyPrefix: "BW_MCP_",
            library: library,
            showBudget: { [weak self] url in self?.showBudgetRequestedByMcp(at: url) }
        )
        libraryEvents.handler = { [weak self] event in self?.handle(event) }
        shareBudgetsWithMcp()
        refreshMcpState()

        cloudChanges.handler = { [weak self] url in self?.reloadBudget(changedAt: url) }
        iCloud.start()
        iCloud.includeSharedBudgets(among: recentFiles)
        Task { await googleDrive.refresh() }
        // Pull other people's changes into an open cloud budget.
        cloudSyncTimer = Timer.publish(every: 60, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.syncOpenCloudBudget() }
    }

    // MARK: Cloud budgets

    /// Recent budgets that are not listed under iCloud Drive or Google Drive.
    var localRecentFiles: [URL] {
        recentFiles.filter { !googleDrive.isCloudURL($0) && !iCloud.contains($0) }
    }

    private var openBudgetURL: URL? {
        currentBudget?.url.map { URL(fileURLWithPath: $0) }
    }

    /// The open budget, when it is stored in Google Drive.
    var openGoogleDriveBudget: BWCloudBudget? {
        openBudgetURL
            .flatMap { googleDrive.budgetID(for: $0) }
            .flatMap { googleDrive.budget(withID: $0) }
    }

    /// The open budget's file, when it is stored in iCloud Drive.
    var openICloudBudgetURL: URL? {
        openBudgetURL.flatMap { iCloud.contains($0) ? (currentSecurityScopedURL ?? $0) : nil }
    }

    func syncOpenCloudBudget() {
        if let url = openBudgetURL {
            googleDrive.sync(budgetAt: url)
        }
    }

    func openGoogleDriveBudget(_ budget: BWCloudBudget, windowStore: BWWindowStore) async -> Bool {
        do {
            let url = try await googleDrive.open(budget)
            return await openBudget(at: url, windowStore: windowStore)
        } catch {
            windowStore.setError(error)
            return false
        }
    }

    // MARK: MCP server

    func setMcpServerEnabled(_ isEnabled: Bool) {
        mcpServer?.setEnabled(isEnabled)
        refreshMcpState()
    }

    func setMcpServerAllowsNetwork(_ allowsNetwork: Bool) {
        mcpServer?.setAllowsNetwork(allowsNetwork)
        refreshMcpState()
    }

    func regenerateMcpServerURL() {
        mcpServer?.regenerateURL()
        refreshMcpState()
    }

    private func refreshMcpState() {
        mcpSettings = mcpServer?.settings
        mcpStatus = mcpServer?.status
        mcpErrorMessage = mcpServer?.errorMessage
    }

    private func shareBudgetsWithMcp() {
        let openURL = currentBudget?.url.map { path in
            currentSecurityScopedURL.flatMap { scoped in
                scoped.standardizedFileURL.path == URL(fileURLWithPath: path).standardizedFileURL.path
                    ? scoped
                    : nil
            } ?? URL(fileURLWithPath: path)
        }
        library.update(open: openURL, recent: recentFiles, defaultCurrencyCode: defaultCurrency.rawValue)
    }

    /// Follows changes the MCP server or Shortcuts made to budget files.
    private func handle(_ event: BWBudgetLibraryEvent) {
        switch event {
        case .changed(let url):
            reloadBudget(changedAt: url)
            googleDrive.sync(budgetAt: url)
        case .created(let url):
            rememberRecent(url)
        case .deleted(let url):
            let target = url.standardizedFileURL
            if openBudgetURL?.standardizedFileURL == target {
                currentSecurityScopedURL?.stopAccessingSecurityScopedResource()
                currentSecurityScopedURL = nil
                currentBudget = nil
                iCloud.watch(nil)
            }
            let documentController = NSDocumentController.shared
            let remaining = documentController.recentDocumentURLs.filter { $0.standardizedFileURL != target }
            documentController.clearRecentDocuments(nil)
            for recent in remaining.reversed() {
                documentController.noteNewRecentDocumentURL(recent)
            }
            recentFiles = documentController.recentDocumentURLs
            BWAppShortcuts.updateAppShortcutParameters()
        }
    }

    /// Re-reads the open budget after the MCP server or cloud sync changed
    /// its file.
    private func reloadBudget(changedAt url: URL) {
        guard
            let path = currentBudget?.url,
            URL(fileURLWithPath: path).standardizedFileURL == url.standardizedFileURL,
            let reloaded = try? readBudget(at: URL(fileURLWithPath: path)),
            reloaded.revisionId != currentBudget?.revisionId
        else {
            return
        }
        currentBudget = reloaded
    }

    private func showBudgetRequestedByMcp(at url: URL) {
        let isOpen = currentBudget?.url.map {
            URL(fileURLWithPath: $0).standardizedFileURL == url.standardizedFileURL
        } ?? false
        if !isOpen {
            try? openBudget(at: url)
        }
        mcpShowBudgetRequest = UUID()
        NSApp.activate()
    }

    private nonisolated static func mcpBudgetDirectory() -> URL? {
        let documents = FileManager.default
            .url(forUbiquityContainerIdentifier: nil)?
            .appendingPathComponent("Documents", isDirectory: true)
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        return documents?.appendingPathComponent("Budgets", isDirectory: true)
    }

    func createBudget(
        title: String,
        template: BWBudgetTemplateSelection,
        location: BWBudgetLocation = .thisMac,
        windowStore: BWWindowStore
    ) async -> Bool {
        if location != .thisMac {
            return await createCloudBudget(title: title, template: template, location: location, windowStore: windowStore)
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [Self.budgetFileType]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = Self.fileName(for: title)

        guard panel.runModal() == .OK, let url = panel.url else { return false }

        do {
            var newBudget = try newBudget(title: title, template: template)
            newBudget.url = url.path
            try writeBudget(newBudget, to: url)
            selectBudget(newBudget)
            rememberRecent(url)
            return true
        } catch {
            windowStore.setError(error)
            return false
        }
    }

    private func createCloudBudget(
        title: String,
        template: BWBudgetTemplateSelection,
        location: BWBudgetLocation,
        windowStore: BWWindowStore
    ) async -> Bool {
        do {
            let json = try encodeBudget(budget: newBudget(title: title, template: template))
            let fileName = Self.fileName(for: title)
            let url: URL
            if location == .googleDrive {
                url = try await googleDrive.createBudget(fileName: fileName, json: json)
            } else {
                url = try await iCloud.createBudget(fileName: fileName, json: json)
            }
            return await openBudget(at: url, windowStore: windowStore)
        } catch let error as FfiError {
            windowStore.setError(BWError.core(error.message))
            return false
        } catch {
            windowStore.setError(error)
            return false
        }
    }

    /// A new budget in the previous budget's currency, or the default one.
    private func newBudget(title: String, template: BWBudgetTemplateSelection) throws -> BWBudget {
        let budget: BWBudget
        switch template {
        case .builtIn(let id):
            budget = try BWCore.budgetFromTemplateId(templateId: id, title: title)
        case .previousBudget(let previous):
            budget = try BWCore.budgetFromPreviousBudget(budget: previous, title: title)
        }
        return budget.currency == nil
            ? try BWCore.updateBudgetCurrency(budget: budget, currency: defaultCurrency.rawValue)
            : budget
    }

    /// Changes the currency of the open budget. Amounts are not converted.
    func setBudgetCurrency(_ currency: BWCurrency, windowStore: BWWindowStore) {
        guard let budget = currentBudget, budget.currency != currency.rawValue else { return }
        _ = mutate(windowStore: windowStore) {
            try BWCore.updateBudgetCurrency(budget: budget, currency: currency.rawValue)
        }
    }

    func recentBudgetTemplates() -> [BWBudgetTemplateSelection] {
        recentFiles.compactMap { url in
            try? BWBudgetTemplateSelection.previousBudget(readBudget(at: url))
        }
    }

    func selectBudget(_ budget: BWBudget) {
        currentBudget = budget
        if let path = budget.url {
            rememberRecent(URL(fileURLWithPath: path))
        }
    }

    func openFilePicker(windowStore: BWWindowStore) async -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [Self.budgetFileType]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return .none }
        return url;
    }

    func openBudget(at url: URL, windowStore: BWWindowStore) async -> Bool {
        do {
            if iCloud.contains(url) {
                try await iCloud.prepareForOpening(url)
            }
            try openBudget(at: url)
            return true
        } catch {
            windowStore.setError(error)
            return false
        }
    }

    private func openBudget(at url: URL) throws {
        let alreadyScoped = currentSecurityScopedURL?.standardizedFileURL == url.standardizedFileURL
        let scoped = !alreadyScoped && url.startAccessingSecurityScopedResource()
        do {
            let opened = try readBudget(at: url)
            if let previous = currentSecurityScopedURL, previous != url {
                previous.stopAccessingSecurityScopedResource()
            }
            currentSecurityScopedURL = (alreadyScoped || scoped) ? url : nil
            currentBudget = opened
            rememberRecent(url)
            iCloud.watch(iCloud.contains(url) ? url : nil)
        } catch {
            if scoped { url.stopAccessingSecurityScopedResource() }
            throw error
        }
    }

    func createCategory(
        title: String,
        plannedAmount: UInt64,
        categoryType: BWCategoryType,
        windowStore: BWWindowStore
    ) async -> Bool {
        guard let budget = currentBudget, let amount = Int64(exactly: plannedAmount) else { return false }
        let ordinal = budget.categories.filter { $0.categoryType == categoryType }.count
        let category = BWCategory(
            id: UUID(),
            ordinal: Int32(ordinal),
            title: title,
            amountPlanned: BWMoneyAmount(value: amount),
            amountActual: BWMoneyAmount(value: 0),
            amountAccumulated: BWMoneyAmount(value: 0),
            categoryType: categoryType,
            transactions: []
        )
        return mutate(windowStore: windowStore) { try BWCore.createCategory(budget: budget, category: category) }
    }

    func updateCategory(
        _ category: BWCategory,
        in budgetID: UUID,
        windowStore: BWWindowStore
    ) async -> Bool {
        guard
            let budget = currentBudget,
            budget.id == budgetID
        else {
            return false
        }

        var updated = category

        // The inspector edits a snapshot of the category. Keep ordering owned by
        // moveCategory so a delayed inspector save cannot restore a stale ordinal.
        if let currentCategory = budget.categories.first(where: { $0.id == category.id }) {
            updated.ordinal = currentCategory.ordinal
        }

        return mutate(windowStore: windowStore) {
            try BWCore.updateCategory(budget: budget, category: updated)
        }
    }

    func canMoveCategory(_ category: BWCategory, by offset: Int) -> Bool {
        guard let budget = currentBudget else { return false }
        let categories = budget.orderedCategories(for: category.categoryType)
        guard let index = categories.firstIndex(where: { $0.id == category.id }) else { return false }
        return categories.indices.contains(index + offset)
    }

    func moveCategory(_ category: BWCategory, by offset: Int, windowStore: BWWindowStore) async -> Bool {
        guard
            let budget = currentBudget,
            let currentCategory = budget.categories.first(where: { $0.id == category.id })
        else {
            return false
        }

        let categories = budget.orderedCategories(for: currentCategory.categoryType)
        guard
            let currentIndex = categories.firstIndex(where: { $0.id == currentCategory.id }),
            categories.indices.contains(currentIndex + offset)
        else {
            return false
        }

        var updated = currentCategory
        updated.ordinal = Int32(currentIndex + offset)
        return mutate(windowStore: windowStore) {
            try BWCore.updateCategory(budget: budget, category: updated)
        }
    }

    func deleteCategory(_ category: BWCategory, windowStore: BWWindowStore) async {
        guard let budget = currentBudget else { return }
        _ = mutate(windowStore: windowStore) { try BWCore.deleteCategory(budget: budget, categoryId: category.id) }
    }

    func createTransaction(
        categoryID: UUID,
        title: String,
        description: String,
        date: Date,
        amount: UInt64,
        windowStore: BWWindowStore
    ) async -> Bool {
        guard let budget = currentBudget, let amount = Int64(exactly: amount) else { return false }
        let transaction = BWTransaction(
            id: UUID(),
            title: title,
            description: description,
            date: BWDate(date),
            amount: BWMoneyAmount(value: amount)
        )
        return mutate(windowStore: windowStore) {
            try BWCore.createTransaction(budget: budget, categoryId: categoryID, transaction: transaction)
        }
    }

    func updateTransaction(categoryID: UUID, transaction: BWTransaction, windowStore: BWWindowStore) async -> Bool {
        guard let budget = currentBudget else { return false }
        return mutate(windowStore: windowStore) {
            try BWCore.updateTransaction(budget: budget, categoryId: categoryID, transaction: transaction)
        }
    }

    func deleteTransaction(categoryID: UUID, transactionID: UUID, windowStore: BWWindowStore) async {
        guard let budget = currentBudget else { return }
        _ = mutate(windowStore: windowStore) {
            try BWCore.deleteTransaction(budget: budget, categoryId: categoryID, transactionId: transactionID)
        }
    }

    func moveTransaction(
        transactionID: UUID,
        from sourceCategoryID: UUID,
        to destinationCategoryID: UUID,
        windowStore: BWWindowStore
    ) async -> Bool {
        guard let budget = currentBudget else { return false }
        return mutate(windowStore: windowStore) {
            try BWCore.moveTransaction(
                budget: budget,
                originCategoryId: sourceCategoryID,
                targetCategoryId: destinationCategoryID,
                transactionId: transactionID
            )
        }
    }

    private func mutate(windowStore: BWWindowStore, operation: () throws -> BWBudget) -> Bool {
        do {
            var updated = try operation()
            updated = try updated.updateActuals()
            guard let path = updated.url ?? currentBudget?.url else {
                throw BWError.savingFile()
            }
            updated.url = path
            let url = URL(fileURLWithPath: path)
            let inMemory = updated
            // Shared with the MCP server so concurrent saves merge instead of
            // overwriting each other.
            updated = try BWBudgetSaveLock.withLock {
                let onDisk = try readBudget(at: url)
                let merged = try BWCore.mergeBudgetForSave(
                    budgetInMemory: inMemory,
                    budgetOnDisk: onDisk
                ).updateActuals()
                try writeBudget(merged, to: url)
                return merged
            }
            currentBudget = updated
            rememberRecent(url)
            googleDrive.sync(budgetAt: url)
            return true
        } catch let error as FfiError {
            windowStore.setError(BWError.core(error.message))
            return false
        } catch {
            windowStore.setError(error)
            return false
        }
    }

    private func readBudget(at url: URL) throws -> BWBudget {
        do {
            let data = try Data(contentsOf: url)
            guard let json = String(data: data, encoding: .utf8) else {
                throw BWError.readingFile()
            }
            var budget = try decodeBudget(json: json, url: url.path)

            // TEMPORARY LEGACY MIGRATION: remove this writeback branch together
            // with the Rust migration after all live schema-v1 files are upgraded.
            if budget.requiresMigrationWriteback {
                try writeBudget(budget, to: url)
                budget.requiresMigrationWriteback = false
            }

            return budget
        } catch let error as BWError {
            throw error
        } catch let error as FfiError {
            if error.message.hasPrefix("Failed to decode budget from JSON:")
                || error.message.hasPrefix("Failed to migrate legacy budget JSON:") {
                throw BWError.decodingFile(error)
            }
            throw BWError.core(error.message)
        } catch {
            throw BWError.readingFile(error)
        }
    }

    private func writeBudget(_ budget: BWBudget, to url: URL) throws {
        do {
            let json = try encodeBudget(budget: budget)
            try json.write(to: url, atomically: true, encoding: .utf8)
        } catch let error as BWError {
            throw error
        } catch {
            throw BWError.savingFile(error)
        }
    }

    private func rememberRecent(_ url: URL) {
        NSDocumentController.shared.noteNewRecentDocumentURL(url.standardizedFileURL)
        recentFiles = NSDocumentController.shared.recentDocumentURLs
        BWAppShortcuts.updateAppShortcutParameters()
    }

    private static var budgetFileType: UTType {
        UTType(filenameExtension: "budget") ?? .json
    }

    private static func fileName(for title: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:")
        let safe = title.components(separatedBy: invalid).joined(separator: "-")
        return safe.hasSuffix(".budget") ? safe : "\(safe).budget"
    }
}
