import AppKit
import Foundation
import UniformTypeIdentifiers

final class BudgetVault {
    static let shared = BudgetVault()

    private let folderName = "Budget Warden Budgets"
    private let bookmarkKey = "BudgetVaultBookmark"
    private let fileManager = FileManager.default

    private init() {}

    func selectVaultParent(preferICloud: Bool) -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.folder]
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.title = preferICloud ? "Choose iCloud Drive Folder" : "Choose Local Vault Folder"
        panel.message = "Budget Warden will create a \(folderName) folder inside the selected folder."

        if preferICloud {
            panel.directoryURL = fileManager.url(forUbiquityContainerIdentifier: nil)?
                .appendingPathComponent("Documents", isDirectory: true)
        }

        guard panel.runModal() == .OK else {
            return nil
        }

        return panel.url
    }

    func selectBudgetFile() -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "budget") ?? .data]
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        panel.title = "Open Budget"
        panel.message = "Choose a Budget Warden budget file."

        guard panel.runModal() == .OK else {
            return nil
        }

        return panel.url
    }

    func configureVault(parentURL: URL) throws {
        let didAccess = parentURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                parentURL.stopAccessingSecurityScopedResource()
            }
        }

        let vaultURL = parentURL.appendingPathComponent(folderName, isDirectory: true)
        try fileManager.createDirectory(at: vaultURL, withIntermediateDirectories: true)

        let bookmark = try vaultURL.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )

        UserDefaults.standard.set(bookmark, forKey: bookmarkKey)
    }

    func resolveVaultURL() throws -> URL {
        guard let bookmark = UserDefaults.standard.data(forKey: bookmarkKey) else {
            throw BudgetVaultError.vaultNotConfigured
        }

        var isStale = false
        let url = try URL(
            resolvingBookmarkData: bookmark,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )

        if isStale {
            let refreshed = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(refreshed, forKey: bookmarkKey)
        }

        var isDirectory: ObjCBool = false

        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw BudgetVaultError.vaultUnavailable
        }

        return url
    }

    func configuredLocalParentURL() -> URL? {
        guard let vaultURL = try? resolveVaultURL(), !isICloudURL(vaultURL) else {
            return nil
        }

        return vaultURL.deletingLastPathComponent()
    }

    func loadBudgets() throws -> [BudgetDocument] {
        let vaultURL = try resolveVaultURL()
        return try access(vaultURL) {
            let urls = try fileManager.contentsOfDirectory(
                at: vaultURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )

            return urls
                .filter { $0.pathExtension == "budget" }
                .compactMap { try? BudgetCodec.readBudget(from: $0) }
                .sorted(by: Self.sortByFileName)
        }
    }

    func saveBudget(_ draft: BudgetDraft) throws -> BudgetDocument {
        let vaultURL = try resolveVaultURL()

        return try access(vaultURL) {
            let uniqueBudget = uniqueBudgetLocation(for: draft.title, in: vaultURL)
            let json = try BudgetCodec.makeJSON(title: uniqueBudget.title)
            let destination = uniqueBudget.url
            try json.write(to: destination, atomically: true, encoding: .utf8)
            return try BudgetCodec.readBudget(from: destination)
        }
    }

    func addCategory(_ draft: CategoryDraft, to budget: BudgetDocument) throws -> BudgetDocument {
        let vaultURL = try resolveVaultURL()

        return try access(vaultURL) {
            try BudgetCodec.addCategory(draft, to: budget.url)
        }
    }

    func updateCategory(_ update: CategoryUpdate, in budget: BudgetDocument) throws -> BudgetDocument {
        let vaultURL = try resolveVaultURL()

        return try access(vaultURL) {
            try BudgetCodec.updateCategory(update, in: budget.url)
        }
    }

    func removeCategory(_ category: BudgetCategory, from budget: BudgetDocument) throws -> BudgetDocument {
        let vaultURL = try resolveVaultURL()

        return try access(vaultURL) {
            try BudgetCodec.removeCategory(categoryID: category.coreID, from: budget.url)
        }
    }

    func reorderCategories(type: BudgetCategoryType, orderedCategoryIDs: [Int], in budget: BudgetDocument) throws -> BudgetDocument {
        let vaultURL = try resolveVaultURL()

        return try access(vaultURL) {
            try BudgetCodec.reorderCategories(type: type, orderedCategoryIDs: orderedCategoryIDs, in: budget.url)
        }
    }

    func addTransaction(_ draft: TransactionDraft, to budget: BudgetDocument) throws -> BudgetDocument {
        let vaultURL = try resolveVaultURL()

        return try access(vaultURL) {
            try BudgetCodec.addTransaction(draft, to: budget.url)
        }
    }

    func removeBudget(_ budget: BudgetDocument) throws {
        let vaultURL = try resolveVaultURL()

        try access(vaultURL) {
            guard Self.isBudgetFile(budget.url, in: vaultURL) else {
                throw BudgetVaultError.budgetRemoveFailed(budget.url)
            }

            do {
                var trashedURL: NSURL?
                try fileManager.trashItem(at: budget.url, resultingItemURL: &trashedURL)
            } catch {
                throw BudgetVaultError.budgetRemoveFailed(budget.url)
            }
        }
    }

    private func access<T>(_ url: URL, operation: () throws -> T) throws -> T {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        return try operation()
    }

    private func uniqueBudgetLocation(for title: Swift.String, in directory: URL) -> (title: Swift.String, url: URL) {
        let baseName = Self.fileName(from: title)
        var uniqueTitle = baseName
        var candidate = directory.appendingPathComponent(uniqueTitle).appendingPathExtension("budget")
        var suffix = 2

        while fileManager.fileExists(atPath: candidate.path) {
            uniqueTitle = "\(baseName) \(suffix)"
            candidate = directory
                .appendingPathComponent(uniqueTitle)
                .appendingPathExtension("budget")
            suffix += 1
        }

        return (uniqueTitle, candidate)
    }

    nonisolated private static func sortByFileName(_ lhs: BudgetDocument, _ rhs: BudgetDocument) -> Bool {
        return lhs.url.lastPathComponent.localizedStandardCompare(rhs.url.lastPathComponent) == .orderedAscending
    }

    nonisolated private static func isBudgetFile(_ url: URL, in vaultURL: URL) -> Bool {
        url.pathExtension == "budget" &&
            url.deletingLastPathComponent().standardizedFileURL == vaultURL.standardizedFileURL
    }

    private func isICloudURL(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path

        if path.contains("/Mobile Documents/") {
            return true
        }

        guard let iCloudURL = fileManager.url(forUbiquityContainerIdentifier: nil) else {
            return false
        }

        return path.hasPrefix(iCloudURL.standardizedFileURL.path)
    }

    private static func fileName(from title: Swift.String) -> Swift.String {
        let invalid = CharacterSet(charactersIn: "/\\?%*|\"<>:")
        let parts = title
            .components(separatedBy: invalid)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return parts.joined(separator: " ").isEmpty ? "Budget" : parts.joined(separator: " ")
    }
}
