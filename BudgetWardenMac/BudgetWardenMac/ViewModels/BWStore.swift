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
import BWCore

@MainActor
final class BWStore: ObservableObject {
    private static let recentBookmarksKey = "BW_RECENT_BUDGET_BOOKMARKS_V1"
    private static let currencyKey = "BW_CURRENCY"
    private static let deviceIDKey = "BW_DEVICE_ID"

    @Published var currentBudget: BWBudget?
    @Published var recentFiles: [URL] = NSDocumentController.shared.recentDocumentURLs
    @Published var selectedCurrency: BWCurrency {
        didSet { UserDefaults.standard.set(selectedCurrency.rawValue, forKey: Self.currencyKey) }
    }

    private var currentSecurityScopedURL: URL?

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
    }

    func createBudget(
        title: String,
        template: BWTemplateType,
        windowStore: BWWindowStore
    ) async -> Bool {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [Self.budgetFileType]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = Self.fileName(for: title)

        guard panel.runModal() == .OK, let url = panel.url else { return false }

        do {
            var newBudget = BWCore.budgetFromTemplate(template: template, title: title)
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

    func recentBudgetTemplates() -> [BWTemplateType] {
        recentFiles.compactMap { url in
            try? BWTemplateType.previousBudget(readBudget(at: url))
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
        let scoped = url.startAccessingSecurityScopedResource()
        do {
            let opened = try readBudget(at: url)
            if let previous = currentSecurityScopedURL, previous != url {
                previous.stopAccessingSecurityScopedResource()
            }
            currentSecurityScopedURL = scoped ? url : nil
            currentBudget = opened
            rememberRecent(url)
            return true
        } catch {
            if scoped { url.stopAccessingSecurityScopedResource() }
            windowStore.setError(error)
            return false
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

    func updateCategory(_ category: BWCategory, windowStore: BWWindowStore) async -> Bool {
        guard let budget = currentBudget else { return false }
        return mutate(windowStore: windowStore) { try BWCore.updateCategory(budget: budget, category: category) }
    }

    func canMoveCategory(_ category: BWCategory, by offset: Int) -> Bool {
        guard let budget = currentBudget else { return false }
        let categories = budget.orderedCategories(for: category.categoryType)
        guard let index = categories.firstIndex(where: { $0.id == category.id }) else { return false }
        return categories.indices.contains(index + offset)
    }

    func moveCategory(_ category: BWCategory, by offset: Int, windowStore: BWWindowStore) async -> Bool {
        guard canMoveCategory(category, by: offset) else { return false }
        var updated = category
        updated.ordinal += Int32(offset)
        return await updateCategory(updated, windowStore: windowStore)
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
            updated.updateActuals()
            guard let path = updated.url ?? currentBudget?.url else {
                throw BWError.savingFile()
            }
            updated.url = path
            let url = URL(fileURLWithPath: path)
            try writeBudget(updated, to: url)
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
            return try decodeBudget(json: json, url: url.path)
        } catch let error as BWError {
            throw error
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
