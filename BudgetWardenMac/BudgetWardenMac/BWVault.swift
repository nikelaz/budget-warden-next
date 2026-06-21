/* 
 * Budget Warden
 * Copyright (c) 2026 Lazarov & Co EOOD
 * Author: Nikola Lazarov
 *
 * Licensed under the Source-Available Educational License. 
 * See the LICENSE file in the project root for full terms.
 *
 */

import Foundation
import AppKit
import AppleCore

enum BWVaultLocation: String, CaseIterable, Identifiable, Sendable {
    case local
    case iCloud

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
            case .local:
                return "Local Folder"
            case .iCloud:
                return "iCloud Drive"
        }
    }
}

struct BWVaultReadResult: Sendable {
    var budgets: [BWBudget]
    var skippedFiles: [String]
}

actor BWVault: Sendable {
    private static let vaultBookmarkKey = "BW_VAULT_BOOKMARK"
    private static let vaultLocationKey = "BW_VAULT_LOCATION"
    private static let localVaultBookmarkKey = "BW_LOCAL_VAULT_BOOKMARK"
    private static let iCloudVaultBookmarkKey = "BW_ICLOUD_VAULT_BOOKMARK"
    private static let defaultVaultFolderName = "Budget Warden Vaults"

    var url: URL?
    private var location: BWVaultLocation
    
    private var fileManager: FileManager {
        FileManager.default
    }

    init() {
        let savedLocation = UserDefaults.standard.string(forKey: Self.vaultLocationKey)
            .flatMap(BWVaultLocation.init(rawValue:))
        self.location = savedLocation ?? .local

        switch Self.resolveVaultURL(location: location) {
            case .success(let url):
                self.url = url
            case .failure:
                self.url = nil
        }
    }

    // Runs on the UI thread because it opens a file dialog
    @MainActor
    func selectVaultFolder() async -> Result<Void, BWError> {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK else {
            return .failure(.saveCancelled())
        }

        guard let url = panel.url else {
            return .failure(.vaultNotSet())
        }

        do {
            let bookmark = try url.bookmarkData(
                options: .withSecurityScope,
            )

            UserDefaults.standard.set(bookmark, forKey: Self.bookmarkKey(location: await currentLocation()))

            await setUrl(url)
            
            return .success(())
        }
        catch {
            return .failure(.vaultNotSet(underlying: error))
        }
    }

    // This setter is necessary as otherwise the UI thread selectVaultFolder()
    // cannot access this class to set the URL property
    private func setUrl(_ url: URL) {
        self.url = url
    }

    func currentLocation() -> BWVaultLocation {
        location
    }

    func setLocation(_ location: BWVaultLocation) async -> Result<Void, BWError> {
        let oldLocation = self.location
        let oldURL = self.url

        switch Self.resolveVaultURL(location: location) {
            case .success(let url):
                self.location = location
                self.url = url
                UserDefaults.standard.set(location.rawValue, forKey: Self.vaultLocationKey)
                return .success(())
            case .failure(let error):
                self.location = oldLocation
                self.url = oldURL
                return .failure(error)
        }
    }
 
    func readBudgetsFromVault() async -> Result<BWVaultReadResult, BWError> {
        guard let url else {
            let resolveRes = Self.resolveVaultURL(location: location)

            switch resolveRes {
                case .success(let url):
                    self.url = url
                    return await readBudgetsFromVault()
                case .failure(let error):
                    return .failure(error)
            }
        }

        return await Task.detached(priority: .userInitiated) {
            Self.readBudgetsFromDirectory(url: url)
        }.value
    }

    func currentURL() -> URL? {
        url
    }

    func containsBudgetFile(url budgetURL: URL) -> Bool {
        guard let url else {
            return false
        }

        let directoryURL = url.standardizedFileURL
        let fileURL = budgetURL.standardizedFileURL

        guard fileURL.pathExtension.lowercased() == "budget" else {
            return false
        }

        return fileURL.deletingLastPathComponent() == directoryURL
    }

    func saveNewBudgetInVault(
        fileName: String,
        fileExtension: String,
        contents: String
    ) async -> Result<URL, BWError> {
        guard let url else {
            return .failure(.vaultNotSet())
        }

        return await Task.detached(priority: .userInitiated) {
            let didStartAccessing = url.startAccessingSecurityScopedResource()

            defer {
                if didStartAccessing {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            let fileUrl = BWVault.makeUniqueVaultFileURL(
                directoryURL: url,
                fileName: fileName,
                fileExtension: fileExtension
            )

            let saveFileRes = BWFiles.saveFile(
                url: fileUrl,
                contents: contents
            )

            switch saveFileRes {
                case .failure(let error):
                    return .failure(error)
                case .success:
                    return .success(fileUrl)
            }
        }.value
    }

    func saveBudgetFile(url budgetURL: URL, contents: String) async -> Result<Void, BWError> {
        guard let url else {
            return .failure(.vaultNotSet())
        }

        return await Task.detached(priority: .userInitiated) {
            let didStartAccessing = url.startAccessingSecurityScopedResource()

            defer {
                if didStartAccessing {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            let directoryURL = url.standardizedFileURL
            let fileURL = budgetURL.standardizedFileURL

            guard fileURL.pathExtension.lowercased() == "budget" else {
                return .failure(.savingFile())
            }

            guard fileURL.deletingLastPathComponent() == directoryURL else {
                return .failure(.savingFile())
            }

            return BWFiles.saveFile(
                url: fileURL,
                contents: contents
            )
        }.value
    }

    func removeBudgetFromVault(url budgetURL: URL) async -> Result<Void, BWError> {
        guard let url else {
            return .failure(.vaultNotSet())
        }

        return await Task.detached(priority: .userInitiated) {
            let didStartAccessing = url.startAccessingSecurityScopedResource()

            defer {
                if didStartAccessing {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            let directoryURL = url.standardizedFileURL
            let fileURL = budgetURL.standardizedFileURL

            guard fileURL.pathExtension.lowercased() == "budget" else {
                return .failure(.budgetRemove())
            }

            guard fileURL.deletingLastPathComponent() == directoryURL else {
                return .failure(.budgetRemove())
            }

            do {
                try FileManager.default.trashItem(at: fileURL, resultingItemURL: nil)
                return .success(())
            }
            catch {
                return .failure(.budgetRemove(underlying: error))
            }
        }.value
    }

    private static func readBudgetsFromDirectory(url: URL) -> Result<BWVaultReadResult, BWError> {
        let didStartAccessing = url.startAccessingSecurityScopedResource()

        defer {
            if didStartAccessing {
                url.stopAccessingSecurityScopedResource()
            }
        }

        do {
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: true
            )

            let files = try FileManager.default.contentsOfDirectory(
                    at: url,
                    includingPropertiesForKeys: nil
                    )

                let budgetFiles = files.filter {
                    $0.pathExtension.lowercased() == "budget"
                }

            var budgets: [BWBudget] = []
            var skippedFiles: [String] = []

                for file in budgetFiles {
                    guard let json = try? String(contentsOf: file, encoding: .utf8) else {
                        skippedFiles.append(file.lastPathComponent)
                        continue
                    }

                    switch BWCodec.decodeBudget(json: json, url: file) {
                        case .success(let budget):
                            budgets.append(budget)

                        case .failure:
                                skippedFiles.append(file.lastPathComponent)
                                continue
                    }
                }

            return .success(BWVaultReadResult(
                budgets: budgets,
                skippedFiles: skippedFiles
            ))
        } catch {
                return .failure(.vaultNotSet(underlying: error))
        }
    }

    private static func resolveVaultURL(location: BWVaultLocation) -> Result<URL, BWError> {
        if let bookmarkedUrl = resolveBookmarkedVaultURL(location: location) {
            return .success(bookmarkedUrl)
        }

        do {
            let url: URL

            switch location {
                case .local:
                    url = try defaultLocalVaultURL()
                case .iCloud:
                    url = try defaultICloudVaultURL()
            }

            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: true
            )

            return .success(url)
        }
        catch {
            switch location {
                case .local:
                    return .failure(.vaultNotSet(underlying: error))
                case .iCloud:
                    return .failure(.iCloudUnavailable(underlying: error))
            }
        }
    }

    private static func resolveBookmarkedVaultURL(location: BWVaultLocation) -> URL? {
        // Legacy key keeps existing users on their previously selected local vault.
        let key = bookmarkKey(location: location)
        let bookmark = UserDefaults.standard.data(forKey: key)
            ?? (location == .local ? UserDefaults.standard.data(forKey: vaultBookmarkKey) : nil)

        guard let bookmark else {
            return nil
        }

        do {
            var isStale = false

            let url = try URL(
                resolvingBookmarkData: bookmark,
                options: .withSecurityScope,
                bookmarkDataIsStale: &isStale
            )

            if isStale,
               let freshBookmark = try? url.bookmarkData(options: .withSecurityScope) {
                UserDefaults.standard.set(freshBookmark, forKey: key)
            }

            return url
        }
        catch {
            return nil
        }
    }

    private static func bookmarkKey(location: BWVaultLocation) -> String {
        switch location {
            case .local:
                return localVaultBookmarkKey
            case .iCloud:
                return iCloudVaultBookmarkKey
        }
    }

    private static func defaultLocalVaultURL() throws -> URL {
        let documentsURL = try FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )

        return documentsURL.appendingPathComponent(defaultVaultFolderName)
    }

    private static func defaultICloudVaultURL() throws -> URL {
        if let containerURL = FileManager.default.url(forUbiquityContainerIdentifier: nil) {
            return containerURL
                .appendingPathComponent("Documents")
                .appendingPathComponent(defaultVaultFolderName)
        }

        let cloudDocsURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library")
            .appendingPathComponent("Mobile Documents")
            .appendingPathComponent("com~apple~CloudDocs")

        guard FileManager.default.fileExists(atPath: cloudDocsURL.path) else {
            throw BWError.iCloudUnavailable()
        }

        return cloudDocsURL
            .appendingPathComponent(defaultVaultFolderName)
    }

    private static func makeUniqueVaultFileURL(
        directoryURL: URL,
        fileName: String,
        fileExtension: String
    ) -> URL {
        var candidateURL = directoryURL
            .appendingPathComponent(fileName)
            .appendingPathExtension(fileExtension)

        var index = 2

        while FileManager.default.fileExists(atPath: candidateURL.path) {
            candidateURL = directoryURL
                .appendingPathComponent("\(fileName) \(index)")
                .appendingPathExtension(fileExtension)

            index += 1
        }

        return candidateURL
    }
}
