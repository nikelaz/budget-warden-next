/* 
 * Budget Warden
 * Copyright (c) 2026 Lazarov & Co EOOD
 * Author: Nikola Lazarov
 *
 * Licensed under the Source-Available Educational License. 
 * See the LICENSE file in the project root for full terms.
 *
 */

import AppKit
import Foundation
import UniformTypeIdentifiers

final class BWBudgetVault {
    static let shared = BWBudgetVault()

    private let folderName = "Budget Warden Budgets"
    private let bookmarkKey = "BudgetVaultBookmark"
    private let fileManager = FileManager.default

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
            throw BWError.vaultNotConfigured
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
            throw BWError.vaultUnavailable
        }

        return url
    }

    func configuredLocalParentURL() -> URL? {
        guard let vaultURL = try? resolveVaultURL(), !isICloudURL(vaultURL) else {
            return nil
        }

        return vaultURL.deletingLastPathComponent()
    }

    func budgetFileURLs(in vaultURL: URL) throws -> [URL] {
        let urls = try fileManager.contentsOfDirectory(
            at: vaultURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )

        return urls.filter { $0.pathExtension == "budget" }
    }

    static func loadBudgetRows(in vaultURL: URL) throws -> [BudgetRow] {
        try accessSecurityScopedResource(vaultURL) {
            let urls = try FileManager.default.contentsOfDirectory(
                at: vaultURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            .filter { $0.pathExtension == "budget" }

            let rows = try urls.map { url -> BudgetRow in
                let key = budgetKey(for: url)
                let budget = try readBudget(at: key)

                return BudgetRow(
                    url: key,
                    budgetID: budget.id,
                    title: budget.title.swiftString(default: key.deletingPathExtension().lastPathComponent)
                )
            }

            return rows.sorted(by: sortByFileName)
        }
    }

    func uniqueBudgetLocation(for title: Swift.String, in directory: URL) -> (title: Swift.String, url: URL) {
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

    func isBudgetInConfiguredVault(_ url: URL) -> Bool {
        guard let vaultURL = try? resolveVaultURL() else {
            return false
        }

        return Self.isBudgetFile(url, in: vaultURL)
    }

    func accessVault<T>(_ operation: () throws -> T) throws -> T {
        let vaultURL = try resolveVaultURL()
        return try Self.accessSecurityScopedResource(vaultURL, operation: operation)
    }

    static func accessSecurityScopedResource<T>(_ url: URL, operation: () throws -> T) throws -> T {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        return try operation()
    }

    private static func isBudgetFile(_ url: URL, in vaultURL: URL) -> Bool {
        url.pathExtension == "budget" &&
            url.deletingLastPathComponent().standardizedFileURL == vaultURL.standardizedFileURL
    }

    nonisolated private static func sortByFileName(_ lhs: BudgetRow, _ rhs: BudgetRow) -> Bool {
        lhs.url.lastPathComponent.localizedStandardCompare(rhs.url.lastPathComponent) == .orderedAscending
    }

    private static func readBudget(at url: URL) throws -> Budget {
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(Budget.self, from: data)
        } catch {
            throw BWError.budgetReadFailed(url)
        }
    }

    private static func budgetKey(for url: URL) -> URL {
        url.standardizedFileURL
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
