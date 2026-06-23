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
    case iCloud
    case local

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

typealias BWVaultReadResult = BWBudgetDirectoryReadResult

actor BWVault: Sendable {
    private static let vaultLocationKey = "BWI_VAULT_LOCATION"
    private static let localVaultBookmarkKey = "BWI_LOCAL_VAULT_BOOKMARK"
    private static let defaultVaultFolderName = "Budget Warden Vaults"
    private static let uiTestVaultFolderName = "Budget Warden UI Test Vault"

    private var url: URL?
    private var location: BWVaultLocation

    init() {
        let savedLocation = UserDefaults.standard.string(forKey: Self.vaultLocationKey)
            .flatMap(BWVaultLocation.init(rawValue:))
        let initialLocation = savedLocation ?? Self.defaultLocation

        (location, url) = Self.resolveInitialVault(location: initialLocation)
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

        return BWBudgetFileStore.isBudgetFile(budgetURL, in: url)
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

            let fileURL = BWBudgetFileStore.makeUniqueVaultFileURL(
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

            guard BWBudgetFileStore.isBudgetFile(budgetURL, in: url) else {
                return .failure(.savingFile())
            }

            return BWFiles.saveFile(url: budgetURL.standardizedFileURL, contents: contents)
        }.value
    }

    func saveBudgetFile(
        _ budget: BWBudget,
        baseBudget: BWBudget?,
        deviceID: String
    ) async -> Result<BWBudgetSaveOutcome, BWError> {
        guard let url else {
            return .failure(.vaultNotSet())
        }

        guard let budgetURL = budget.url else {
            return .failure(.saveFailed())
        }

        return await Task.detached(priority: .userInitiated) {
            let didStartAccessing = url.startAccessingSecurityScopedResource()

            defer {
                if didStartAccessing {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            guard BWBudgetFileStore.isBudgetFile(budgetURL, in: url) else {
                return .failure(.savingFile())
            }

            return BWBudgetFileStore.saveBudget(
                budget,
                baseBudget: baseBudget,
                to: budgetURL.standardizedFileURL,
                modifiedByDeviceID: deviceID
            )
        }.value
    }

    func resolveBudgetFileConflict(
        _ conflict: BWBudgetSaveConflict,
        choice: BWBudgetConflictChoice,
        deviceID: String
    ) async -> Result<BWBudgetSaveOutcome, BWError> {
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

            guard BWBudgetFileStore.isBudgetFile(conflict.fileURL, in: url) else {
                return .failure(.savingFile())
            }

            return BWBudgetFileStore.resolveSaveConflict(
                conflict,
                choice: choice,
                modifiedByDeviceID: deviceID
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

            guard BWBudgetFileStore.isBudgetFile(budgetURL, in: url) else {
                return .failure(.budgetRemove())
            }

            do {
                try FileManager.default.removeItem(at: budgetURL.standardizedFileURL)
                return .success(())
            }
            catch {
                return .failure(.budgetRemove(underlying: error))
            }
        }.value
    }

    private static func readBudgetsFromDirectory(url: URL) -> Result<BWVaultReadResult, BWError> {
        return BWBudgetFileStore.readBudgetsFromDirectory(url: url, sortedByTitle: true)
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

    private static func resolveInitialVault(location: BWVaultLocation) -> (BWVaultLocation, URL?) {
        switch resolveVaultURL(location: location) {
            case .success(let url):
                return (location, url)
            case .failure:
                guard location == .iCloud else {
                    return (location, nil)
                }

                switch resolveVaultURL(location: .local) {
                    case .success(let url):
                        return (.local, url)
                    case .failure:
                        return (location, nil)
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

        return documentsURL.appendingPathComponent(localVaultFolderName)
    }

    private static func defaultICloudVaultURL() throws -> URL {
        guard let containerURL = FileManager.default.url(forUbiquityContainerIdentifier: nil) else {
            throw BWError.iCloudUnavailable()
        }

        return containerURL
            .appendingPathComponent("Documents")
            .appendingPathComponent(defaultVaultFolderName)
    }

    private static var localVaultFolderName: String {
        BWUITestSupport.isEnabled ? uiTestVaultFolderName : defaultVaultFolderName
    }

    private static var defaultLocation: BWVaultLocation {
        BWUITestSupport.isEnabled ? .local : .iCloud
    }

    static func resetUITestState() {
        UserDefaults.standard.removeObject(forKey: vaultLocationKey)
        UserDefaults.standard.removeObject(forKey: localVaultBookmarkKey)

        do {
            let documentsURL = try FileManager.default.url(
                for: .documentDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let testVaultURL = documentsURL.appendingPathComponent(uiTestVaultFolderName)

            if FileManager.default.fileExists(atPath: testVaultURL.path) {
                try FileManager.default.removeItem(at: testVaultURL)
            }
        }
        catch {
            // UI tests will surface vault setup failures during app launch.
        }
    }
}
