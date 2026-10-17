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
import UniformTypeIdentifiers
import BWAppleCore

enum BWBudgetTemplateSelection: Hashable {
    case builtIn(String)
    case previousBudget(BWBudget)
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
        didSet { shareBudgetsWithMcp() }
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

    private var currentSecurityScopedURL: URL?
    var hasAttemptedLegacyMigration = false

    init() {
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
            budgetDidChange: { [weak self] url in self?.reloadBudgetChangedByMcp(at: url) },
            budgetWasCreated: { [weak self] url in self?.rememberRecent(url) },
            showBudget: { [weak self] url in self?.showBudgetRequestedByMcp(at: url) }
        )
        shareBudgetsWithMcp()
        refreshMcpState()
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

    private func reloadBudgetChangedByMcp(at url: URL) {
        guard
            let path = currentBudget?.url,
            URL(fileURLWithPath: path).standardizedFileURL == url.standardizedFileURL,
            let reloaded = try? readBudget(at: URL(fileURLWithPath: path))
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
        windowStore: BWWindowStore
    ) async -> Bool {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [Self.budgetFileType]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = Self.fileName(for: title)

        guard panel.runModal() == .OK, let url = panel.url else { return false }

        do {
            var newBudget: BWBudget
            switch template {
            case .builtIn(let id):
                newBudget = try BWCore.budgetFromTemplateId(
                    templateId: id,
                    title: title
                )
            case .previousBudget(let budget):
                newBudget = try BWCore.budgetFromPreviousBudget(
                    budget: budget,
                    title: title
                )
            }
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
            try openBudget(at: url)
            return true
        } catch {
            windowStore.setError(error)
            return false
        }
    }

    private func openBudget(at url: URL) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        do {
            let opened = try readBudget(at: url)
            if let previous = currentSecurityScopedURL, previous != url {
                previous.stopAccessingSecurityScopedResource()
            }
            currentSecurityScopedURL = scoped ? url : nil
            currentBudget = opened
            rememberRecent(url)
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
