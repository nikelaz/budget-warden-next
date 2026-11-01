/*
 * Budget Warden
 * Copyright (c) 2026 Lazarov & Co EOOD
 * Author: Nikola Lazarov
 *
 * Licensed under the Source-Available Educational License.
 * See the LICENSE file in the project root for full terms.
 */

import BWAppleCore
import Foundation
import AppIntents
import Observation
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let budgetWardenBudget = UTType(
        exportedAs: "com.lazarovco.budgetwarden.budget",
        conformingTo: .json
    )
}

enum BWTemplateSelection: Hashable {
    case builtIn(String)
    case previous(URL)
}

/// Where a new budget is stored.
enum BWBudgetLocation: Hashable, CaseIterable {
    /// A location the user picks in the Files browser.
    case files
    case iCloud
    case googleDrive

    var title: String {
        switch self {
        case .files: "Choose in Files"
        case .iCloud: "iCloud Drive"
        case .googleDrive: "Google Drive"
        }
    }
}

struct BWBudgetFileDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.budgetWardenBudget]
    static let writableContentTypes: [UTType] = [.budgetWardenBudget]

    let json: String

    init(json: String) {
        self.json = json
    }

    init(configuration: ReadConfiguration) throws {
        guard
            let data = configuration.file.regularFileContents,
            let json = String(data: data, encoding: .utf8)
        else {
            throw BWError.readingFile()
        }
        self.json = json
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        guard let data = json.data(using: .utf8) else {
            throw BWError.savingFile()
        }
        return FileWrapper(regularFileWithContents: data)
    }
}

@MainActor
@Observable
final class BWStore {
    private static let recentBookmarksKey = "BWI_RECENT_BUDGET_BOOKMARKS_V1"
    private static let currencyKey = "BWI_CURRENCY"
    private static let deviceIDKey = "BWI_DEVICE_ID"

    private(set) var currentBudget: BWBudget? {
        didSet { shareBudgetsWithMcp() }
    }
    private(set) var recentFiles: [URL] = [] {
        didSet {
            shareBudgetsWithMcp()
            iCloud.includeSharedBudgets(among: recentFiles)
        }
    }
    var errorMessage: String?
    var selectedCurrency: BWCurrency {
        didSet {
            UserDefaults.standard.set(selectedCurrency.rawValue, forKey: Self.currencyKey)
            shareBudgetsWithMcp()
        }
    }
    private(set) var mcpSettings: BWMcpSettings?
    private(set) var mcpStatus: BWMcpServerStatus?
    private(set) var mcpErrorMessage: String?

    @ObservationIgnored private var mcpServer: BWMcpServerController?

    /// Budgets in Google Drive, including ones shared with the user.
    let googleDrive: BWGoogleDriveController
    /// Budgets in iCloud Drive.
    let iCloud: BWICloudBudgetLibrary
    private let cloudChanges: BWBudgetChangeRelay
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

        loadRecentFiles()

        mcpServer = BWMcpServerController(
            keyPrefix: "BWI_MCP_",
            newBudgetDirectory: { BWStore.mcpBudgetDirectory() },
            budgetDidChange: { [weak self] url in self?.reloadBudget(changedAt: url) },
            budgetWasCreated: { [weak self] url in self?.rememberRecent(url) },
            showBudget: { [weak self] url in
                Task { await self?.openBudget(at: url) }
            }
        )
        shareBudgetsWithMcp()
        refreshMcpState()

        cloudChanges.handler = { [weak self] url in self?.reloadBudget(changedAt: url) }
        iCloud.start()
        iCloud.includeSharedBudgets(among: recentFiles)
        Task { await googleDrive.refresh() }
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

    /// Pulls other people's changes into an open cloud budget and refreshes
    /// the cloud lists, for example when the app returns to the foreground.
    func syncCloudBudgets() {
        if let url = openBudgetURL {
            googleDrive.sync(budgetAt: url)
        }
    }

    @discardableResult
    func openGoogleDriveBudget(_ budget: BWCloudBudget) async -> Bool {
        do {
            let url = try await googleDrive.open(budget)
            return await openBudget(at: url)
        } catch {
            report(error)
            return false
        }
    }

    /// Creates a budget in iCloud Drive or Google Drive and opens it.
    func createCloudBudget(
        title: String,
        template: BWTemplateSelection,
        location: BWBudgetLocation
    ) async -> Bool {
        do {
            let document = try makeBudgetDocument(title: title, template: template)
            let fileName = Self.fileName(for: title)
            let url: URL
            if location == .googleDrive {
                url = try await googleDrive.createBudget(fileName: fileName, json: document.json)
            } else {
                url = try await iCloud.createBudget(fileName: fileName, json: document.json)
            }
            return await openBudget(at: url)
        } catch {
            report(error)
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

    /// iOS closes listening sockets while the app is suspended; listen again
    /// when it becomes active.
    func restartMcpServerIfEnabled() {
        guard mcpSettings?.isEnabled == true else { return }
        mcpServer?.restartIfEnabled()
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
            let reloaded = try? readBudget(at: currentSecurityScopedURL ?? URL(fileURLWithPath: path)),
            reloaded.revisionId != currentBudget?.revisionId
        else {
            return
        }
        currentBudget = reloaded
    }

    private nonisolated static func mcpBudgetDirectory() -> URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Budgets", isDirectory: true)
    }

    var selectedBudgetID: UUID? {
        currentBudget?.id
    }

    func budget(withID budgetID: UUID) -> BWBudget? {
        guard currentBudget?.id == budgetID else { return nil }
        return currentBudget
    }

    @discardableResult
    func openBudget(at url: URL) async -> Bool {
        // Keep the original URL: a normalized copy may not carry its sandbox extension.
        let isAlreadyScoped = currentSecurityScopedURL?.standardizedFileURL
            == url.standardizedFileURL
        let acquiredScope = isAlreadyScoped ? false : url.startAccessingSecurityScopedResource()

        do {
            if iCloud.contains(url) {
                try await iCloud.prepareForOpening(url)
            }
            let opened = try readBudget(at: url)

            if !isAlreadyScoped {
                currentSecurityScopedURL?.stopAccessingSecurityScopedResource()
                currentSecurityScopedURL = acquiredScope ? url : nil
            }

            currentBudget = opened
            errorMessage = nil
            rememberRecent(url)
            iCloud.watch(iCloud.contains(url) ? url : nil)
            return true
        } catch {
            if acquiredScope {
                url.stopAccessingSecurityScopedResource()
            }
            report(error)
            removeRecent(url)
            return false
        }
    }

    func closeBudget() {
        currentSecurityScopedURL?.stopAccessingSecurityScopedResource()
        currentSecurityScopedURL = nil
        currentBudget = nil
        iCloud.watch(nil)
    }

    func removeRecent(_ url: URL) {
        let target = url.standardizedFileURL
        let bookmarks = storedRecentBookmarks().filter { bookmark in
            guard let resolved = resolveBookmark(bookmark) else { return false }
            return resolved.standardizedFileURL != target
        }
        saveRecentBookmarks(bookmarks)
        recentFiles.removeAll { $0.standardizedFileURL == target }
    }

    func deleteRecentBudget(at url: URL) {
        let isAlreadyScoped = currentSecurityScopedURL?.standardizedFileURL
            == url.standardizedFileURL
        let acquiredScope = isAlreadyScoped ? false : url.startAccessingSecurityScopedResource()
        defer {
            if acquiredScope {
                url.stopAccessingSecurityScopedResource()
            }
        }

        do {
            try coordinatedDelete(at: url)
            removeRecent(url)
            errorMessage = nil
        } catch {
            report(BWError.deletingBudget(error))
        }
    }

    func makeBudgetDocument(
        title: String,
        template: BWTemplateSelection
    ) throws -> BWBudgetFileDocument {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            throw BWError.validation("Budget title cannot be empty.")
        }

        let budget: BWBudget
        switch template {
        case .builtIn(let id):
            budget = try BWCore.budgetFromTemplateId(templateId: id, title: trimmedTitle)
        case .previous(let url):
            let scoped = url.startAccessingSecurityScopedResource()
            defer {
                if scoped {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            let previous = try readBudget(at: url)
            budget = try BWCore.budgetFromPreviousBudget(budget: previous, title: trimmedTitle)
        }

        do {
            return BWBudgetFileDocument(json: try BWCore.encodeBudget(budget: budget))
        } catch let error as FfiError {
            throw BWError.core(error.message)
        } catch {
            throw BWError.creatingBudget(error)
        }
    }

    static func fileName(for title: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:")
        let safe = title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: invalid)
            .joined(separator: "-")
        return safe.hasSuffix(".budget") ? safe : "\(safe).budget"
    }

    func createCategory(
        in budgetID: UUID,
        title: String,
        plannedAmount: UInt64,
        categoryType: BWCategoryType
    ) async -> Bool {
        guard
            let budget = budget(withID: budgetID),
            let amount = Int64(exactly: plannedAmount)
        else {
            report(BWError.validation("The planned amount is too large."))
            return false
        }

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
        return mutate {
            try BWCore.createCategory(budget: $0, category: category)
        }
    }

    func updateBudgetTitle(_ title: String, for budgetID: UUID) async -> Bool {
        guard currentBudget?.id == budgetID else { return false }
        return mutate { budget in
            try BWCore.updateBudgetTitle(budget: budget, title: title)
        }
    }

    func updateCategory(_ updatedCategory: BWCategory, in budgetID: UUID) async -> Bool {
        guard currentBudget?.id == budgetID else { return false }
        return mutate { budget in
            try BWCore.updateCategory(budget: budget, category: updatedCategory)
        }
    }

    func deleteCategory(_ category: BWCategory, in budgetID: UUID) async {
        guard currentBudget?.id == budgetID else { return }
        _ = mutate { budget in
            try BWCore.deleteCategory(budget: budget, categoryId: category.id)
        }
    }

    func moveCategories(
        in budgetID: UUID,
        for categoryType: BWCategoryType,
        fromOffsets sourceOffsets: IndexSet,
        toOffset destination: Int
    ) async -> Bool {
        guard let budget = budget(withID: budgetID) else { return false }

        var desiredIDs = budget.orderedCategories(for: categoryType).map(\.id)
        desiredIDs.move(fromOffsets: sourceOffsets, toOffset: destination)

        return mutate { startingBudget in
            var updatedBudget = startingBudget

            for (targetOrdinal, categoryID) in desiredIDs.enumerated() {
                let ordered = updatedBudget.orderedCategories(for: categoryType)
                guard
                    ordered.indices.contains(targetOrdinal),
                    ordered[targetOrdinal].id != categoryID,
                    var category = ordered.first(where: { $0.id == categoryID })
                else {
                    continue
                }

                category.ordinal = Int32(targetOrdinal)
                updatedBudget = try BWCore.updateCategory(
                    budget: updatedBudget,
                    category: category
                )
            }

            return updatedBudget
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
        guard
            currentBudget?.id == budgetID,
            let value = Int64(exactly: amount)
        else {
            report(BWError.validation("The transaction amount is too large."))
            return false
        }

        return mutate { budget in
            let transaction = try BWCore.newTransaction(
                title: title,
                description: description,
                date: BWDate(date),
                amount: BWMoneyAmount(value: value)
            )
            return try BWCore.createTransaction(
                budget: budget,
                categoryId: categoryID,
                transaction: transaction
            )
        }
    }

    func updateTransaction(
        _ transaction: BWTransaction,
        in budgetID: UUID,
        from sourceCategoryID: UUID,
        to destinationCategoryID: UUID
    ) async -> Bool {
        guard currentBudget?.id == budgetID else { return false }

        return mutate { budget in
            var updated = try BWCore.updateTransaction(
                budget: budget,
                categoryId: sourceCategoryID,
                transaction: transaction
            )

            if sourceCategoryID != destinationCategoryID {
                updated = try BWCore.moveTransaction(
                    budget: updated,
                    originCategoryId: sourceCategoryID,
                    targetCategoryId: destinationCategoryID,
                    transactionId: transaction.id
                )
            }

            return updated
        }
    }

    func deleteTransaction(
        _ transaction: BWTransaction,
        in budgetID: UUID,
        from categoryID: UUID
    ) async {
        guard currentBudget?.id == budgetID else { return }
        _ = mutate { budget in
            try BWCore.deleteTransaction(
                budget: budget,
                categoryId: categoryID,
                transactionId: transaction.id
            )
        }
    }

    private func mutate(_ operation: (BWBudget) throws -> BWBudget) -> Bool {
        guard let budget = currentBudget, let path = budget.url else { return false }

        do {
            var updated = try operation(budget)
            updated = try updated.updateActuals()
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
            errorMessage = nil
            rememberRecent(url)
            googleDrive.sync(budgetAt: url)
            return true
        } catch let error as FfiError {
            report(BWError.core(error.message))
            return false
        } catch {
            report(error)
            return false
        }
    }

    private func readBudget(at url: URL) throws -> BWBudget {
        do {
            let data = try coordinatedRead(at: url)
            guard let json = String(data: data, encoding: .utf8) else {
                throw BWError.readingFile()
            }
            var budget = try BWCore.decodeBudget(json: json, url: url.path)

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
            let json = try BWCore.encodeBudget(budget: budget)
            guard let data = json.data(using: .utf8) else {
                throw BWError.savingFile()
            }
            try coordinatedWrite(data, to: url)
        } catch let error as BWError {
            throw error
        } catch let error as FfiError {
            throw BWError.core(error.message)
        } catch {
            throw BWError.savingFile(error)
        }
    }

    private func coordinatedRead(at url: URL) throws -> Data {
        var coordinationError: NSError?
        var result: Result<Data, Error>?

        NSFileCoordinator().coordinate(
            readingItemAt: url,
            options: [],
            error: &coordinationError
        ) { coordinatedURL in
            result = Result { try Data(contentsOf: coordinatedURL) }
        }

        if let coordinationError {
            throw coordinationError
        }
        guard let result else {
            throw BWError.readingFile()
        }
        return try result.get()
    }

    private func coordinatedWrite(_ data: Data, to url: URL) throws {
        var coordinationError: NSError?
        var writeError: Error?

        NSFileCoordinator().coordinate(
            writingItemAt: url,
            options: .forReplacing,
            error: &coordinationError
        ) { coordinatedURL in
            do {
                try data.write(to: coordinatedURL, options: .atomic)
            } catch {
                writeError = error
            }
        }

        if let coordinationError {
            throw coordinationError
        }
        if let writeError {
            throw writeError
        }
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

        if let coordinationError {
            throw coordinationError
        }
        if let deleteError {
            throw deleteError
        }
    }

    private func loadRecentFiles() {
        var validBookmarks: [Data] = []
        var urls: [URL] = []

        for bookmark in storedRecentBookmarks() {
            var isStale = false
            guard let url = resolveBookmark(bookmark, isStale: &isStale) else { continue }
            let standardizedURL = url.standardizedFileURL
            guard !urls.contains(where: { $0.standardizedFileURL == standardizedURL }) else {
                continue
            }
            let validBookmark = isStale
                ? (try? makeRecentBookmark(for: url)) ?? bookmark
                : bookmark
            validBookmarks.append(validBookmark)
            // Retain the URL returned by bookmark resolution so it can start its scope later.
            urls.append(url)
        }

        recentFiles = urls
        saveRecentBookmarks(validBookmarks)
    }

    private func rememberRecent(_ url: URL) {
        let standardizedURL = url.standardizedFileURL
        let bookmarkURL = currentSecurityScopedURL.flatMap { currentURL in
            currentURL.standardizedFileURL == standardizedURL ? currentURL : nil
        } ?? url

        do {
            let bookmark = try makeRecentBookmark(for: bookmarkURL)
            var bookmarks = storedRecentBookmarks().filter { existing in
                resolveBookmark(existing)?.standardizedFileURL != standardizedURL
            }
            bookmarks.insert(bookmark, at: 0)
            saveRecentBookmarks(Array(bookmarks.prefix(20)))

            recentFiles.removeAll { $0.standardizedFileURL == standardizedURL }
            recentFiles.insert(bookmarkURL, at: 0)
            if recentFiles.count > 20 {
                recentFiles.removeLast(recentFiles.count - 20)
            }
        } catch {
            // The open file remains usable even if the provider cannot issue a bookmark.
        }
        BWAppShortcuts.updateAppShortcutParameters()
    }

    func remapRecentFiles(using entries: [BWLegacyBudgetMigrationEntry]) {
        let mappings = Dictionary(
            entries.map {
                ($0.sourceURL.standardizedFileURL, $0.destinationURL.standardizedFileURL)
            },
            uniquingKeysWith: { _, latest in latest }
        )
        guard !mappings.isEmpty else {
            return
        }

        var seen = Set<URL>()
        let migrated = entries.compactMap { entry -> URL? in
            let url = entry.destinationURL.standardizedFileURL
            return seen.insert(url).inserted ? url : nil
        }
        let remappedExisting = recentFiles.compactMap { recentURL -> URL? in
            let standardizedURL = recentURL.standardizedFileURL
            let url = mappings[standardizedURL] ?? recentURL
            return seen.insert(url).inserted ? url : nil
        }

        let updatedRecents = Array((migrated + remappedExisting).prefix(20))
        let bookmarks = updatedRecents.compactMap { url in
            try? makeRecentBookmark(for: url)
        }
        saveRecentBookmarks(bookmarks)
        recentFiles = updatedRecents
        BWAppShortcuts.updateAppShortcutParameters()
    }

    private func storedRecentBookmarks() -> [Data] {
        UserDefaults.standard.array(forKey: Self.recentBookmarksKey) as? [Data] ?? []
    }

    private func saveRecentBookmarks(_ bookmarks: [Data]) {
        UserDefaults.standard.set(bookmarks, forKey: Self.recentBookmarksKey)
    }

    private func resolveBookmark(_ bookmark: Data) -> URL? {
        var isStale = false
        return resolveBookmark(bookmark, isStale: &isStale)
    }

    private func resolveBookmark(_ bookmark: Data, isStale: inout Bool) -> URL? {
        try? URL(
            resolvingBookmarkData: bookmark,
            options: [.withoutUI, .withoutImplicitStartAccessing],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
    }

    private func makeRecentBookmark(for url: URL) throws -> Data {
        // iOS embeds the picker-granted scope when the original URL is bookmarked
        // while security-scoped access is active.
        let isAlreadyScoped = currentSecurityScopedURL?.standardizedFileURL
            == url.standardizedFileURL
        let acquiredScope = isAlreadyScoped ? false : url.startAccessingSecurityScopedResource()
        defer {
            if acquiredScope {
                url.stopAccessingSecurityScopedResource()
            }
        }

        return try url.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    private func report(_ error: Error) {
        errorMessage = error.localizedDescription
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
            let isCurrent = currentSecurityScopedURL?.standardizedFileURL == url.standardizedFileURL
            let acquired = isCurrent ? false : url.startAccessingSecurityScopedResource()
            defer { if acquired { url.stopAccessingSecurityScopedResource() } }
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
        errorMessage = nil
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
        if hasCurrentScope { closeBudget() }
        currentBudget = nil
        removeRecent(url)
        errorMessage = nil
    }

    func intentCategories(budgetID: UUID?, categoryType: BWShortcutCategoryType?) async throws -> [BWShortcutCategory] {
        let budgets = try await intentBudgets().filter { budgetID == nil || $0.id == budgetID }
        var categories: [BWShortcutCategory] = []
        for entry in budgets {
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

    private func intentReadBudget(_ id: UUID) throws -> BWBudget {
        if let currentBudget, currentBudget.id == id { return currentBudget }
        for url in recentFiles {
            let isCurrent = currentSecurityScopedURL?.standardizedFileURL == url.standardizedFileURL
            let acquired = isCurrent ? false : url.startAccessingSecurityScopedResource()
            defer { if acquired { url.stopAccessingSecurityScopedResource() } }
            if let budget = try? readBudget(at: url), budget.id == id { return budget }
        }
        throw BWIntentStoreError("That budget file is no longer available. Open it in Budget Warden first.")
    }

    private func intentSelectBudget(_ id: UUID) async throws -> BWBudget {
        if let currentBudget, currentBudget.id == id { return currentBudget }
        for url in recentFiles {
            let isCurrent = currentSecurityScopedURL?.standardizedFileURL == url.standardizedFileURL
            let acquired = isCurrent ? false : url.startAccessingSecurityScopedResource()
            defer { if acquired { url.stopAccessingSecurityScopedResource() } }
            guard let candidate = try? readBudget(at: url), candidate.id == id else { continue }
            guard await openBudget(at: url) else {
                throw BWIntentStoreError(errorMessage ?? "Could not open that budget file.")
            }
            guard let opened = currentBudget else { throw BWIntentStoreError("Could not open that budget file.") }
            return opened
        }
        throw BWIntentStoreError("Open this budget in Budget Warden before using it with Siri or Shortcuts.")
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
        errorMessage = nil
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
}

private struct BWIntentStoreError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
