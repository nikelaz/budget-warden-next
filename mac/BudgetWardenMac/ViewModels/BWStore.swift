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
    @Published var selectedCurrency: BWCurrency {
        didSet {
            UserDefaults.standard.set(selectedCurrency.rawValue, forKey: Self.currencyKey)
            shareBudgetsWithMcp()
        }
    }
    @Published private(set) var mcpSettings: BWMcpSettings?
    @Published private(set) var mcpStatus: BWMcpServerStatus?
    @Published private(set) var mcpErrorMessage: String?
    /// Changes when an MCP client asks the app to show a budget.
    @Published private(set) var mcpShowBudgetRequest = UUID()

    private var mcpServer: BWMcpServerController?

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
        googleDrive = BWGoogleDriveController { url in cloudChanges.notify(url) }
        iCloud = BWICloudBudgetLibrary { url in cloudChanges.notify(url) }

        let defaults = UserDefaults.standard
        selectedCurrency = defaults.string(forKey: Self.currencyKey)
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
            newBudgetDirectory: { BWStore.mcpBudgetDirectory() },
            budgetDidChange: { [weak self] url in self?.reloadBudget(changedAt: url) },
            budgetWasCreated: { [weak self] url in self?.rememberRecent(url) },
            showBudget: { [weak self] url in self?.showBudgetRequestedByMcp(at: url) }
        )
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
        mcpServer?.updateBudgets(
            open: openURL,
            recent: recentFiles,
            currencyCode: selectedCurrency.rawValue
        )
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
            var newBudget = try Self.newBudget(title: title, template: template)
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
            let json = try encodeBudget(budget: Self.newBudget(title: title, template: template))
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

    private static func newBudget(title: String, template: BWBudgetTemplateSelection) throws -> BWBudget {
        switch template {
        case .builtIn(let id):
            return try BWCore.budgetFromTemplateId(templateId: id, title: title)
        case .previousBudget(let budget):
            return try BWCore.budgetFromPreviousBudget(budget: budget, title: title)
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

// MARK: - App Intents

extension BWStore: BWIntentDataSource {
    func intentBudgets() async throws -> [BWShortcutBudget] {
        var budgets: [BWShortcutBudget] = []
        var seen = Set<UUID>()
        if let currentBudget, seen.insert(currentBudget.id).inserted {
            budgets.append(BWShortcutBudget(id: currentBudget.id, title: currentBudget.title))
        }
        for url in recentFiles {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let budget = try? readBudget(at: url), seen.insert(budget.id).inserted else { continue }
            budgets.append(BWShortcutBudget(id: budget.id, title: budget.title))
        }
        return budgets
    }

    func intentCreateBudget(title: String, templateID: String) async throws -> BWShortcutBudget {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw BWIntentStoreError("Budget name cannot be empty.") }
        var budget = try BWCore.budgetFromTemplateId(templateId: templateID, title: title)
        let documents = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let directory = documents.appendingPathComponent("Budget Warden", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var url = directory.appendingPathComponent(Self.fileName(for: title))
        let base = url.deletingPathExtension().lastPathComponent
        var suffix = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("\(base)-\(suffix).budget")
            suffix += 1
        }
        budget.url = url.path
        try writeBudget(budget, to: url)
        currentSecurityScopedURL?.stopAccessingSecurityScopedResource()
        currentSecurityScopedURL = nil
        currentBudget = budget
        rememberRecent(url)
        return BWShortcutBudget(id: budget.id, title: budget.title)
    }

    func intentRenameBudget(id: UUID, title: String) async throws -> BWShortcutBudget {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw BWIntentStoreError("Budget name cannot be empty.") }
        _ = try await intentSelectBudget(id)
        let updated = try intentMutate { try BWCore.updateBudgetTitle(budget: $0, title: title) }
        return BWShortcutBudget(id: updated.id, title: updated.title)
    }

    func intentDeleteBudget(id: UUID) async throws {
        _ = try await intentSelectBudget(id)
        guard let budget = currentBudget, let path = budget.url else {
            throw BWIntentStoreError("That budget is not a saved file.")
        }
        let url = URL(fileURLWithPath: path)
        let hasCurrentScope = currentSecurityScopedURL?.standardizedFileURL == url.standardizedFileURL
        let acquiredScope = hasCurrentScope ? false : url.startAccessingSecurityScopedResource()
        defer { if acquiredScope { url.stopAccessingSecurityScopedResource() } }

        try coordinatedDelete(at: url)
        if hasCurrentScope {
            currentSecurityScopedURL?.stopAccessingSecurityScopedResource()
            currentSecurityScopedURL = nil
        }
        currentBudget = nil

        let documentController = NSDocumentController.shared
        let remaining = documentController.recentDocumentURLs.filter {
            $0.standardizedFileURL != url.standardizedFileURL
        }
        documentController.clearRecentDocuments(nil)
        for recent in remaining.reversed() {
            documentController.noteNewRecentDocumentURL(recent)
        }
        recentFiles = documentController.recentDocumentURLs
    }

    func intentCategories(budgetID: UUID?, categoryType: BWShortcutCategoryType?) async throws -> [BWShortcutCategory] {
        let budgets = try await intentBudgets()
        let selected = budgets.filter { budgetID == nil || $0.id == budgetID }
        var categories: [BWShortcutCategory] = []
        for entry in selected {
            let budget = try intentReadBudget(entry.id)
            categories.append(contentsOf: budget.orderedCategories(categoryType: categoryType?.coreValue).map {
                BWShortcutCategory(
                    id: $0.id, budgetID: budget.id, budgetTitle: budget.title, currencyCode: selectedCurrency.rawValue,
                    title: $0.title, categoryType: BWShortcutCategoryType($0.categoryType),
                    plannedAmount: $0.amountPlanned.value, actualAmount: $0.amountActual.value
                )
            })
        }
        return categories
    }

    func intentCreateCategory(budgetID: UUID, title: String, plannedAmount: Int64, categoryType: BWShortcutCategoryType) async throws -> BWShortcutCategory {
        let budget = try await intentSelectBudget(budgetID)
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw BWIntentStoreError("Category name cannot be empty.") }
        let ordinal = budget.categories.filter { $0.categoryType == categoryType.coreValue }.count
        let category = BWCategory(
            id: UUID(), ordinal: Int32(ordinal), title: title,
            amountPlanned: BWMoneyAmount(value: plannedAmount), amountActual: BWMoneyAmount(value: 0),
            amountAccumulated: BWMoneyAmount(value: 0), categoryType: categoryType.coreValue, transactions: []
        )
        let updated = try intentMutate { try BWCore.createCategory(budget: $0, category: category) }
        return intentCategory(category, in: updated)
    }

    func intentUpdateCategory(id: UUID, budgetID: UUID, title: String?, plannedAmount: Int64?, categoryType: BWShortcutCategoryType?) async throws -> BWShortcutCategory {
        let budget = try await intentSelectBudget(budgetID)
        guard var category = budget.categories.first(where: { $0.id == id }) else {
            throw BWIntentStoreError("That category is no longer in this budget.")
        }
        if let title {
            let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { throw BWIntentStoreError("Category name cannot be empty.") }
            category.title = title
        }
        if let plannedAmount { category.amountPlanned = BWMoneyAmount(value: plannedAmount) }
        if let categoryType {
            let newType = categoryType.coreValue
            if newType != category.categoryType {
                category.ordinal = Int32(budget.categories.filter { $0.categoryType == newType }.count)
            }
            category.categoryType = newType
        }
        let updated = try intentMutate { try BWCore.updateCategory(budget: $0, category: category) }
        guard let saved = updated.categories.first(where: { $0.id == id }) else {
            throw BWIntentStoreError("The category could not be found after saving.")
        }
        return intentCategory(saved, in: updated)
    }

    func intentDeleteCategory(id: UUID, budgetID: UUID) async throws {
        _ = try await intentSelectBudget(budgetID)
        _ = try intentMutate { try BWCore.deleteCategory(budget: $0, categoryId: id) }
    }

    func intentTransactions(budgetID: UUID?, categoryID: UUID?, search: String?, limit: Int) async throws -> [BWShortcutTransaction] {
        let budgets = try await intentBudgets().filter { budgetID == nil || $0.id == budgetID }
        var transactions: [BWShortcutTransaction] = []
        let query = search?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for entry in budgets {
            let budget = try intentReadBudget(entry.id)
            for category in budget.orderedCategories(categoryType: nil) where categoryID == nil || category.id == categoryID {
                for transaction in category.transactions {
                    if let query, !query.isEmpty,
                       !transaction.title.localizedStandardContains(query),
                       !transaction.description.localizedStandardContains(query) { continue }
                    transactions.append(BWShortcutTransaction(
                        id: transaction.id, budgetID: budget.id, budgetTitle: budget.title, currencyCode: selectedCurrency.rawValue,
                        categoryID: category.id, categoryTitle: category.title, title: transaction.title,
                        details: transaction.description, date: transaction.date.foundationDate,
                        amount: transaction.amount.value
                    ))
                }
            }
        }
        return Array(transactions.sorted { $0.date > $1.date }.prefix(max(limit, 0)))
    }

    func intentCreateTransaction(budgetID: UUID, categoryID: UUID, title: String, description: String?, date: Date, amount: Int64) async throws -> BWShortcutTransaction {
        let budget = try await intentSelectBudget(budgetID)
        guard budget.categories.contains(where: { $0.id == categoryID }) else {
            throw BWIntentStoreError("Choose a category from this budget.")
        }
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw BWIntentStoreError("Transaction name cannot be empty.") }
        let transaction = try BWCore.newTransaction(
            title: title, description: description, date: BWDate(date), amount: BWMoneyAmount(value: amount)
        )
        let updated = try intentMutate {
            try BWCore.createTransaction(budget: $0, categoryId: categoryID, transaction: transaction)
        }
        guard let savedCategory = updated.categories.first(where: { $0.id == categoryID }),
              let savedTransaction = savedCategory.transactions.first(where: { $0.id == transaction.id }) else {
            throw BWIntentStoreError("The transaction could not be found after saving.")
        }
        return intentTransaction(savedTransaction, category: savedCategory, budget: updated)
    }

    func intentUpdateTransaction(id: UUID, budgetID: UUID, title: String?, description: String?, date: Date?, amount: Int64?, categoryID: UUID?) async throws -> BWShortcutTransaction {
        let budget = try await intentSelectBudget(budgetID)
        guard let sourceCategory = budget.categories.first(where: { $0.transactions.contains(where: { $0.id == id }) }),
              let transaction = sourceCategory.transactions.first(where: { $0.id == id }) else {
            throw BWIntentStoreError("That transaction is no longer in this budget.")
        }
        guard let destination = categoryID.flatMap({ id in budget.categories.first(where: { $0.id == id }) }) ?? (categoryID == nil ? sourceCategory : nil) else {
            throw BWIntentStoreError("Choose a category from this budget.")
        }
        var changed = transaction
        if let title {
            let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { throw BWIntentStoreError("Transaction name cannot be empty.") }
            changed.title = title
        }
        if let description { changed.description = description }
        if let date { changed.date = BWDate(date) }
        if let amount { changed.amount = BWMoneyAmount(value: amount) }
        let updated = try intentMutate { starting in
            var saved = try BWCore.updateTransaction(budget: starting, categoryId: sourceCategory.id, transaction: changed)
            if destination.id != sourceCategory.id {
                saved = try BWCore.moveTransaction(budget: saved, originCategoryId: sourceCategory.id, targetCategoryId: destination.id, transactionId: id)
            }
            return saved
        }
        guard let savedCategory = updated.categories.first(where: { $0.id == destination.id }),
              let saved = savedCategory.transactions.first(where: { $0.id == id }) else {
            throw BWIntentStoreError("The transaction could not be found after saving.")
        }
        return intentTransaction(saved, category: savedCategory, budget: updated)
    }

    func intentDeleteTransaction(id: UUID, budgetID: UUID) async throws {
        let budget = try await intentSelectBudget(budgetID)
        guard let category = budget.categories.first(where: { $0.transactions.contains(where: { $0.id == id }) }) else {
            throw BWIntentStoreError("That transaction is no longer in this budget.")
        }
        _ = try intentMutate { try BWCore.deleteTransaction(budget: $0, categoryId: category.id, transactionId: id) }
    }

    func intentReport(budgetID: UUID) async throws -> BWShortcutReport {
        let budget = try intentReadBudget(budgetID)
        let summary = try BWCore.buildReportingSummary(budget: budget)
        return BWShortcutReport(
            budgetTitle: budget.title, currencyCode: selectedCurrency.rawValue,
            income: summary.totals.income.value, plannedSpending: summary.totals.plannedSpending.value,
            actualSpending: summary.totals.actualSpending.value, plannedSavings: summary.totals.plannedSavings.value,
            leftToBudget: summary.totals.leftToBudget
        )
    }

    private func intentSelectBudget(_ id: UUID) async throws -> BWBudget {
        if let currentBudget, currentBudget.id == id { return currentBudget }
        for url in recentFiles {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let budget = try? readBudget(at: url), budget.id == id else { continue }
            let windowStore = BWWindowStore()
            guard await openBudget(at: url, windowStore: windowStore), let opened = currentBudget else {
                throw BWIntentStoreError(windowStore.errorMessage.isEmpty ? "Could not open that budget file." : windowStore.errorMessage)
            }
            return opened
        }
        throw BWIntentStoreError("Open this budget in Budget Warden before using it with Siri or Shortcuts.")
    }

    private func intentReadBudget(_ id: UUID) throws -> BWBudget {
        if let currentBudget, currentBudget.id == id { return currentBudget }
        for url in recentFiles {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            if let budget = try? readBudget(at: url), budget.id == id { return budget }
        }
        throw BWIntentStoreError("That budget file is no longer available. Open it in Budget Warden first.")
    }

    private func intentMutate(_ operation: (BWBudget) throws -> BWBudget) throws -> BWBudget {
        guard let budget = currentBudget, let path = budget.url else {
            throw BWIntentStoreError("Open a saved budget before changing it.")
        }
        var updated = try operation(budget).updateActuals()
        updated.url = path
        let url = URL(fileURLWithPath: path)
        updated = try BWCore.mergeBudgetForSave(budgetInMemory: updated, budgetOnDisk: readBudget(at: url)).updateActuals()
        try writeBudget(updated, to: url)
        currentBudget = updated
        rememberRecent(url)
        return updated
    }

    private func intentCategory(_ category: BWCategory, in budget: BWBudget) -> BWShortcutCategory {
        BWShortcutCategory(
            id: category.id, budgetID: budget.id, budgetTitle: budget.title, currencyCode: selectedCurrency.rawValue, title: category.title,
            categoryType: BWShortcutCategoryType(category.categoryType),
            plannedAmount: category.amountPlanned.value, actualAmount: category.amountActual.value
        )
    }

    private func intentTransaction(_ transaction: BWTransaction, category: BWCategory, budget: BWBudget) -> BWShortcutTransaction {
        BWShortcutTransaction(
            id: transaction.id, budgetID: budget.id, budgetTitle: budget.title, currencyCode: selectedCurrency.rawValue,
            categoryID: category.id, categoryTitle: category.title, title: transaction.title,
            details: transaction.description, date: transaction.date.foundationDate, amount: transaction.amount.value
        )
    }

    private func coordinatedDelete(at url: URL) throws {
        var coordinationError: NSError?
        var deleteError: Error?
        NSFileCoordinator().coordinate(
            writingItemAt: url,
            options: .forDeleting,
            error: &coordinationError
        ) { coordinatedURL in
            do {
                try FileManager.default.removeItem(at: coordinatedURL)
            } catch {
                deleteError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let deleteError { throw deleteError }
    }
}

private struct BWIntentStoreError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
