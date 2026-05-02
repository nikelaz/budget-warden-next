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
                .sorted(by: Self.sortByPeriodStart)
        }
    }

    func saveBudget(_ draft: BudgetDraft) throws -> BudgetDocument {
        let vaultURL = try resolveVaultURL()

        return try access(vaultURL) {
            let json = try BudgetCodec.makeJSON(from: draft)
            let destination = uniqueBudgetURL(for: draft.title, in: vaultURL)
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

    func addTransaction(_ draft: TransactionDraft, to budget: BudgetDocument) throws -> BudgetDocument {
        let vaultURL = try resolveVaultURL()

        return try access(vaultURL) {
            try BudgetCodec.addTransaction(draft, to: budget.url)
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

    private func uniqueBudgetURL(for title: Swift.String, in directory: URL) -> URL {
        let baseName = Self.fileName(from: title)
        var candidate = directory.appendingPathComponent(baseName).appendingPathExtension("budget")
        var suffix = 2

        while fileManager.fileExists(atPath: candidate.path) {
            candidate = directory
                .appendingPathComponent("\(baseName) \(suffix)")
                .appendingPathExtension("budget")
            suffix += 1
        }

        return candidate
    }

    nonisolated private static func sortByPeriodStart(_ lhs: BudgetDocument, _ rhs: BudgetDocument) -> Bool {
        if lhs.periodStart.year != rhs.periodStart.year {
            return lhs.periodStart.year < rhs.periodStart.year
        }

        if lhs.periodStart.month != rhs.periodStart.month {
            return lhs.periodStart.month < rhs.periodStart.month
        }

        if lhs.periodStart.day != rhs.periodStart.day {
            return lhs.periodStart.day < rhs.periodStart.day
        }

        return lhs.url.lastPathComponent.localizedStandardCompare(rhs.url.lastPathComponent) == .orderedAscending
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
