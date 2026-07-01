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

public enum BWVaultLocation: String, CaseIterable, Identifiable, Sendable {
    case iCloud
    case local

    public var id: String {
        rawValue
    }

    public var title: String {
        switch self {
            case .local:
                return "Local Folder"
            case .iCloud:
                return "iCloud Drive"
        }
    }
}

public struct BWVaultConfiguration: Sendable {
    public var vaultLocationKey: String
    public var localVaultBookmarkKey: String
    public var iCloudVaultBookmarkKey: String?
    public var legacyLocalVaultBookmarkKey: String?
    public var defaultVaultFolderName: String
    public var localVaultFolderName: String
    public var defaultLocation: BWVaultLocation
    public var iCloudContainerIdentifier: String?
    public var allowsICloudDriveFallback: Bool
    public var localBookmarkCreationOptions: URL.BookmarkCreationOptions
    public var localBookmarkResolutionOptions: URL.BookmarkResolutionOptions
    public var iCloudBookmarkResolutionOptions: URL.BookmarkResolutionOptions
    public var deleteBudgetFile: @Sendable (_ url: URL) throws -> Void

    public init(
        vaultLocationKey: String,
        localVaultBookmarkKey: String,
        iCloudVaultBookmarkKey: String? = nil,
        legacyLocalVaultBookmarkKey: String? = nil,
        defaultVaultFolderName: String,
        localVaultFolderName: String? = nil,
        defaultLocation: BWVaultLocation,
        iCloudContainerIdentifier: String?,
        allowsICloudDriveFallback: Bool = false,
        localBookmarkCreationOptions: URL.BookmarkCreationOptions = [],
        localBookmarkResolutionOptions: URL.BookmarkResolutionOptions = [],
        iCloudBookmarkResolutionOptions: URL.BookmarkResolutionOptions = [],
        deleteBudgetFile: @escaping @Sendable (_ url: URL) throws -> Void
    ) {
        self.vaultLocationKey = vaultLocationKey
        self.localVaultBookmarkKey = localVaultBookmarkKey
        self.iCloudVaultBookmarkKey = iCloudVaultBookmarkKey
        self.legacyLocalVaultBookmarkKey = legacyLocalVaultBookmarkKey
        self.defaultVaultFolderName = defaultVaultFolderName
        self.localVaultFolderName = localVaultFolderName ?? defaultVaultFolderName
        self.defaultLocation = defaultLocation
        self.iCloudContainerIdentifier = iCloudContainerIdentifier
        self.allowsICloudDriveFallback = allowsICloudDriveFallback
        self.localBookmarkCreationOptions = localBookmarkCreationOptions
        self.localBookmarkResolutionOptions = localBookmarkResolutionOptions
        self.iCloudBookmarkResolutionOptions = iCloudBookmarkResolutionOptions
        self.deleteBudgetFile = deleteBudgetFile
    }
}

public actor BWVault: Sendable {
    private let configuration: BWVaultConfiguration
    private var url: URL?
    private var location: BWVaultLocation

    public init(configuration: BWVaultConfiguration) {
        self.configuration = configuration

        let savedLocation = UserDefaults.standard.string(forKey: configuration.vaultLocationKey)
            .flatMap(BWVaultLocation.init(rawValue:))
        let initialLocation = savedLocation ?? configuration.defaultLocation

        (self.location, self.url) = Self.resolveInitialVault(
            location: initialLocation,
            configuration: configuration
        )
    }

    public func currentLocation() -> BWVaultLocation {
        location
    }

    public func currentURL() -> URL? {
        url
    }

    public func setLocation(_ location: BWVaultLocation) async -> Result<Void, BWError> {
        let oldLocation = self.location
        let oldURL = self.url

        switch Self.resolveVaultURL(location: location, configuration: configuration) {
            case .success(let url):
                self.location = location
                self.url = url
                UserDefaults.standard.set(location.rawValue, forKey: configuration.vaultLocationKey)
                return .success(())
            case .failure(let error):
                self.location = oldLocation
                self.url = oldURL
                return .failure(error)
        }
    }

    public func setLocalVaultFolder(_ folderURL: URL) async -> Result<Void, BWError> {
        let didStartAccessing = folderURL.startAccessingSecurityScopedResource()

        defer {
            if didStartAccessing {
                folderURL.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let bookmark = try folderURL.bookmarkData(options: configuration.localBookmarkCreationOptions)
            UserDefaults.standard.set(bookmark, forKey: configuration.localVaultBookmarkKey)
            UserDefaults.standard.set(BWVaultLocation.local.rawValue, forKey: configuration.vaultLocationKey)

            location = .local
            url = folderURL

            return .success(())
        }
        catch {
            return .failure(.vaultNotSet(underlying: error))
        }
    }

    public func readBudgetsFromVault() async -> Result<BWBudgetDirectoryReadResult, BWError> {
        guard let url else {
            switch Self.resolveVaultURL(location: location, configuration: configuration) {
                case .success(let url):
                    self.url = url
                    return await readBudgetsFromVault()
                case .failure(let error):
                    return .failure(error)
            }
        }

        let configuration = self.configuration

        return await Task.detached(priority: .userInitiated) {
            Self.readBudgetsFromDirectory(url: url, configuration: configuration)
        }.value
    }

    public func budgetFileSnapshot() async -> Result<BWBudgetFileSnapshot, BWError> {
        guard let url else {
            switch Self.resolveVaultURL(location: location, configuration: configuration) {
                case .success(let url):
                    self.url = url
                    return await budgetFileSnapshot()
                case .failure(let error):
                    return .failure(error)
            }
        }

        return await Task.detached(priority: .utility) {
            Self.budgetFileSnapshot(forDirectory: url)
        }.value
    }

    public func containsBudgetFile(url budgetURL: URL) -> Bool {
        guard let url else {
            return false
        }

        return BWFiles.isBudgetFile(budgetURL, in: url)
    }

    public func saveNewBudgetInVault(
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

    public func saveBudgetFile(url budgetURL: URL, contents: String) async -> Result<Void, BWError> {
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

            guard BWFiles.isBudgetFile(budgetURL, in: url) else {
                return .failure(.savingFile())
            }

            return BWFiles.saveFile(url: budgetURL.standardizedFileURL, contents: contents)
        }.value
    }

    public func readBudgetFile(url budgetURL: URL) async -> Result<BWBudget, BWError> {
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

            guard BWFiles.isBudgetFile(budgetURL, in: url) else {
                return .failure(.readingFile())
            }

            return BWFiles.readBudgetFile(url: budgetURL.standardizedFileURL)
        }.value
    }

    public func removeBudgetFromVault(url budgetURL: URL) async -> Result<Void, BWError> {
        guard let url else {
            return .failure(.vaultNotSet())
        }

        let configuration = self.configuration

        return await Task.detached(priority: .userInitiated) {
            let didStartAccessing = url.startAccessingSecurityScopedResource()

            defer {
                if didStartAccessing {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            guard BWFiles.isBudgetFile(budgetURL, in: url) else {
                return .failure(.budgetRemove())
            }

            do {
                try configuration.deleteBudgetFile(budgetURL.standardizedFileURL)
                return .success(())
            }
            catch {
                return .failure(.budgetRemove(underlying: error))
            }
        }.value
    }

    public static func resetStoredState(configuration: BWVaultConfiguration) {
        UserDefaults.standard.removeObject(forKey: configuration.vaultLocationKey)
        UserDefaults.standard.removeObject(forKey: configuration.localVaultBookmarkKey)

        if let iCloudVaultBookmarkKey = configuration.iCloudVaultBookmarkKey {
            UserDefaults.standard.removeObject(forKey: iCloudVaultBookmarkKey)
        }

        if let legacyLocalVaultBookmarkKey = configuration.legacyLocalVaultBookmarkKey {
            UserDefaults.standard.removeObject(forKey: legacyLocalVaultBookmarkKey)
        }
    }

    public static func defaultLocalVaultURL(configuration: BWVaultConfiguration) throws -> URL {
        let documentsURL = try FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )

        return documentsURL.appendingPathComponent(configuration.localVaultFolderName)
    }

    private static func readBudgetsFromDirectory(
        url: URL,
        configuration: BWVaultConfiguration
    ) -> Result<BWBudgetDirectoryReadResult, BWError> {
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

            var budgets: [BWBudget] = []
            var skippedFiles: [String] = []

            for file in files where BWFiles.isBudgetFile(file) {
                switch BWFiles.readBudgetFile(url: file) {
                    case .success(let budget):
                        budgets.append(budget)
                    case .failure:
                        skippedFiles.append(file.lastPathComponent)
                }
            }

            budgets.sort {
                $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }

            return .success(BWBudgetDirectoryReadResult(
                budgets: budgets,
                skippedFiles: skippedFiles
            ))
        }
        catch {
            return .failure(.vaultNotSet(underlying: error))
        }
    }

    private static func budgetFileSnapshot(forDirectory url: URL) -> Result<BWBudgetFileSnapshot, BWError> {
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
                includingPropertiesForKeys: [
                    .contentModificationDateKey,
                    .fileSizeKey
                ]
            )

            let states = files.compactMap { file -> BWBudgetFileState? in
                guard BWFiles.isBudgetFile(file) else {
                    return nil
                }

                switch BWFiles.budgetFileState(url: file) {
                    case .success(let state):
                        return state
                    case .failure:
                        return nil
                }
            }

            return .success(BWBudgetFileSnapshot(files: states))
        }
        catch {
            return .failure(.vaultNotSet(underlying: error))
        }
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

    private static func resolveVaultURL(
        location: BWVaultLocation,
        configuration: BWVaultConfiguration
    ) -> Result<URL, BWError> {
        if let bookmarkedURL = resolveBookmarkedVaultURL(
            location: location,
            configuration: configuration
        ) {
            return .success(bookmarkedURL)
        }

        do {
            let url: URL

            switch location {
                case .local:
                    url = try defaultLocalVaultURL(configuration: configuration)
                case .iCloud:
                    url = try defaultICloudVaultURL(configuration: configuration)
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

    private static func resolveInitialVault(
        location: BWVaultLocation,
        configuration: BWVaultConfiguration
    ) -> (BWVaultLocation, URL?) {
        switch resolveVaultURL(location: location, configuration: configuration) {
            case .success(let url):
                return (location, url)
            case .failure:
                guard location == .iCloud else {
                    return (location, nil)
                }

                switch resolveVaultURL(location: .local, configuration: configuration) {
                    case .success(let url):
                        return (.local, url)
                    case .failure:
                        return (location, nil)
                }
        }
    }

    private static func resolveBookmarkedVaultURL(
        location: BWVaultLocation,
        configuration: BWVaultConfiguration
    ) -> URL? {
        let key: String
        let fallbackKey: String?
        let resolutionOptions: URL.BookmarkResolutionOptions

        switch location {
            case .local:
                key = configuration.localVaultBookmarkKey
                fallbackKey = configuration.legacyLocalVaultBookmarkKey
                resolutionOptions = configuration.localBookmarkResolutionOptions
            case .iCloud:
                guard let iCloudVaultBookmarkKey = configuration.iCloudVaultBookmarkKey else {
                    return nil
                }

                key = iCloudVaultBookmarkKey
                fallbackKey = nil
                resolutionOptions = configuration.iCloudBookmarkResolutionOptions
        }

        let bookmark = UserDefaults.standard.data(forKey: key)
            ?? fallbackKey.flatMap { UserDefaults.standard.data(forKey: $0) }

        guard let bookmark else {
            return nil
        }

        do {
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: bookmark,
                options: resolutionOptions,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )

            if isStale,
               let freshBookmark = refreshedBookmark(
                for: url,
                location: location,
                configuration: configuration
               ) {
                UserDefaults.standard.set(freshBookmark, forKey: key)
            }

            return url
        }
        catch {
            return nil
        }
    }

    private static func refreshedBookmark(
        for url: URL,
        location: BWVaultLocation,
        configuration: BWVaultConfiguration
    ) -> Data? {
        switch location {
            case .local:
                return try? url.bookmarkData(options: configuration.localBookmarkCreationOptions)
            case .iCloud:
                return try? url.bookmarkData()
        }
    }

    private static func defaultICloudVaultURL(configuration: BWVaultConfiguration) throws -> URL {
        if let containerURL = FileManager.default.url(
            forUbiquityContainerIdentifier: configuration.iCloudContainerIdentifier
        ) {
            return containerURL
                .appendingPathComponent("Documents")
                .appendingPathComponent(configuration.defaultVaultFolderName)
        }

        guard configuration.allowsICloudDriveFallback else {
            throw BWError.iCloudUnavailable()
        }

        #if os(macOS)
        let cloudDocsURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library")
            .appendingPathComponent("Mobile Documents")
            .appendingPathComponent("com~apple~CloudDocs")

        guard FileManager.default.fileExists(atPath: cloudDocsURL.path) else {
            throw BWError.iCloudUnavailable()
        }

        return cloudDocsURL
            .appendingPathComponent(configuration.defaultVaultFolderName)
        #else
        throw BWError.iCloudUnavailable()
        #endif
    }
}
