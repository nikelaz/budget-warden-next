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
    case basic
    case blank
    case previous(URL)
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

    private(set) var currentBudget: BWBudget?
    private(set) var recentFiles: [URL] = []
    var errorMessage: String?
    var selectedCurrency: BWCurrency {
        didSet {
            UserDefaults.standard.set(selectedCurrency.rawValue, forKey: Self.currencyKey)
        }
    }

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

        loadRecentFiles()
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
            let opened = try readBudget(at: url)

            if !isAlreadyScoped {
                currentSecurityScopedURL?.stopAccessingSecurityScopedResource()
                currentSecurityScopedURL = acquiredScope ? url : nil
            }

            currentBudget = opened
            errorMessage = nil
            rememberRecent(url)
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
        case .basic:
            budget = BWCore.budgetFromTemplate(template: .basicMonthly, title: trimmedTitle)
        case .blank:
            budget = BWCore.budgetFromTemplate(template: .empty, title: trimmedTitle)
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
            var updated = budget
            updated.title = title
            return updated
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
            try writeBudget(updated, to: url)
            currentBudget = updated
            errorMessage = nil
            rememberRecent(url)
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
