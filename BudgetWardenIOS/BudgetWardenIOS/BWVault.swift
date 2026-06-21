/*
 * Budget Warden
 * Copyright (c) 2026 Lazarov & Co EOOD
 * Author: Nikola Lazarov
 *
 * Licensed under the Source-Available Educational License.
 * See the LICENSE file in the project root for full terms.
 *
 */

import AppleCore
import Foundation

enum BWVaultLocation: String, CaseIterable, Identifiable, Sendable {
    case local
    case iCloud

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
            case .local:
                return "Local Files"
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
    private static let vaultLocationKey = "BWI_VAULT_LOCATION"
    private static let localVaultBookmarkKey = "BWI_LOCAL_VAULT_BOOKMARK"
    private static let defaultVaultFolderName = "Budget Warden Vaults"

    private var url: URL?
    private var location: BWVaultLocation

    init() {
        let savedLocation = UserDefaults.standard.string(forKey: Self.vaultLocationKey)
            .flatMap(BWVaultLocation.init(rawValue:))
        location = savedLocation ?? .local

        switch Self.resolveVaultURL(location: location) {
            case .success(let url):
                self.url = url
            case .failure:
                self.url = nil
        }
    }

    func currentLocation() -> BWVaultLocation {
        location
    }

    func currentURL() -> URL? {
        url
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

    func setLocalVaultFolder(_ folderURL: URL) async -> Result<Void, BWError> {
        let didStartAccessing = folderURL.startAccessingSecurityScopedResource()

        defer {
            if didStartAccessing {
                folderURL.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let bookmark = try folderURL.bookmarkData(options: [])
            UserDefaults.standard.set(bookmark, forKey: Self.localVaultBookmarkKey)

            location = .local
            url = folderURL
            UserDefaults.standard.set(BWVaultLocation.local.rawValue, forKey: Self.vaultLocationKey)

            return .success(())
        }
        catch {
            return .failure(.vaultNotSet(underlying: error))
        }
    }

    func readBudgetsFromVault() async -> Result<BWVaultReadResult, BWError> {
        guard let url else {
            switch Self.resolveVaultURL(location: location) {
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

            do {
                try FileManager.default.createDirectory(
                    at: url,
                    withIntermediateDirectories: true
                )
            }
            catch {
                return .failure(.vaultNotSet(underlying: error))
            }

            let fileURL = Self.makeUniqueVaultFileURL(
                directoryURL: url,
                fileName: fileName,
                fileExtension: fileExtension
            )

            switch BWFiles.saveFile(url: fileURL, contents: contents) {
                case .failure(let error):
                    return .failure(error)
                case .success:
                    return .success(fileURL)
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

            guard fileURL.pathExtension.lowercased() == "budget",
                  fileURL.deletingLastPathComponent() == directoryURL
            else {
                return .failure(.savingFile())
            }

            return BWFiles.saveFile(url: fileURL, contents: contents)
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

            guard fileURL.pathExtension.lowercased() == "budget",
                  fileURL.deletingLastPathComponent() == directoryURL
            else {
                return .failure(.budgetRemove())
            }

            do {
                try FileManager.default.removeItem(at: fileURL)
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
                }
            }

            let sortedBudgets = budgets.sorted {
                $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }

            return .success(BWVaultReadResult(
                budgets: sortedBudgets,
                skippedFiles: skippedFiles
            ))
        }
        catch {
            return .failure(.vaultNotSet(underlying: error))
        }
    }

    private static func resolveVaultURL(location: BWVaultLocation) -> Result<URL, BWError> {
        if location == .local, let bookmarkedURL = resolveBookmarkedLocalVaultURL() {
            return .success(bookmarkedURL)
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

    private static func resolveBookmarkedLocalVaultURL() -> URL? {
        guard let bookmark = UserDefaults.standard.data(forKey: localVaultBookmarkKey) else {
            return nil
        }

        do {
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: bookmark,
                bookmarkDataIsStale: &isStale
            )

            if isStale,
               let freshBookmark = try? url.bookmarkData(options: []) {
                UserDefaults.standard.set(freshBookmark, forKey: localVaultBookmarkKey)
            }

            return url
        }
        catch {
            return nil
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
        guard let containerURL = FileManager.default.url(forUbiquityContainerIdentifier: nil) else {
            throw BWError.iCloudUnavailable()
        }

        return containerURL
            .appendingPathComponent("Documents")
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
