/*
 * Budget Warden
 * Copyright (c) 2026 Lazarov & Co EOOD
 * Author: Nikola Lazarov
 *
 * Licensed under the Source-Available Educational License.
 * See the LICENSE file in the project root for full terms.
 */

import Foundation

public enum BWLegacyBudgetMigrationLocation: String, Sendable {
    case local
    case iCloud
}

public struct BWLegacyBudgetDirectory: Hashable, Sendable {
    public let url: URL
    public let securityScopedRootURL: URL?

    public init(url: URL, securityScopedRootURL: URL? = nil) {
        self.url = url
        self.securityScopedRootURL = securityScopedRootURL
    }
}

public struct BWLegacyBudgetMigrationRequest: Sendable {
    public let localSources: [BWLegacyBudgetDirectory]
    public let localDocumentsRoot: BWLegacyBudgetDirectory?
    public let iCloudSources: [BWLegacyBudgetDirectory]
    public let iCloudDriveRoot: BWLegacyBudgetDirectory?
    public let destinationFolderName: String

    public init(
        localSources: [BWLegacyBudgetDirectory] = [],
        localDocumentsRoot: BWLegacyBudgetDirectory? = nil,
        iCloudSources: [BWLegacyBudgetDirectory] = [],
        iCloudDriveRoot: BWLegacyBudgetDirectory? = nil,
        destinationFolderName: String = "Budgets"
    ) {
        self.localSources = localSources
        self.localDocumentsRoot = localDocumentsRoot
        self.iCloudSources = iCloudSources
        self.iCloudDriveRoot = iCloudDriveRoot
        self.destinationFolderName = destinationFolderName
    }
}

public enum BWLegacyBudgetMigrationOutcome: String, Sendable {
    case moved
    case renamed
    case alreadyPresent
}

public struct BWLegacyBudgetMigrationEntry: Sendable {
    public let location: BWLegacyBudgetMigrationLocation
    public let sourceURL: URL
    public let destinationURL: URL
    public let outcome: BWLegacyBudgetMigrationOutcome
}

public struct BWLegacyBudgetMigrationFailure: Sendable {
    public let location: BWLegacyBudgetMigrationLocation
    public let sourceURL: URL
    public let message: String
}

public struct BWLegacyBudgetMigrationReport: Sendable {
    public let entries: [BWLegacyBudgetMigrationEntry]
    public let failures: [BWLegacyBudgetMigrationFailure]

    public func isComplete(for location: BWLegacyBudgetMigrationLocation) -> Bool {
        !failures.contains { $0.location == location }
    }
}

public enum BWLegacyBudgetMigrator {
    public static func containsBudgetFiles(
        in directories: [BWLegacyBudgetDirectory]
    ) async -> Bool {
        await Task.detached(priority: .utility) {
            let scopes = startSecurityScopedAccess(for: directories)
            defer { stopSecurityScopedAccess(scopes) }

            return uniqueDirectories(directories).contains { directory in
                guard FileManager.default.fileExists(atPath: directory.url.path) else {
                    return false
                }

                let files = try? FileManager.default.contentsOfDirectory(
                    at: directory.url,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles]
                )

                return files?.contains(where: isBudgetFile) == true
            }
        }.value
    }

    public static func migrate(
        _ request: BWLegacyBudgetMigrationRequest
    ) async -> BWLegacyBudgetMigrationReport {
        await Task.detached(priority: .utility) {
            var entries: [BWLegacyBudgetMigrationEntry] = []
            var failures: [BWLegacyBudgetMigrationFailure] = []

            migrate(
                location: .local,
                sources: request.localSources,
                destinationRoot: request.localDocumentsRoot,
                destinationFolderName: request.destinationFolderName,
                entries: &entries,
                failures: &failures
            )

            migrate(
                location: .iCloud,
                sources: request.iCloudSources,
                destinationRoot: request.iCloudDriveRoot,
                destinationFolderName: request.destinationFolderName,
                entries: &entries,
                failures: &failures
            )

            return BWLegacyBudgetMigrationReport(entries: entries, failures: failures)
        }.value
    }

    private static func migrate(
        location: BWLegacyBudgetMigrationLocation,
        sources: [BWLegacyBudgetDirectory],
        destinationRoot: BWLegacyBudgetDirectory?,
        destinationFolderName: String,
        entries: inout [BWLegacyBudgetMigrationEntry],
        failures: inout [BWLegacyBudgetMigrationFailure]
    ) {
        guard !sources.isEmpty, let destinationRoot else {
            return
        }

        let allDirectories = sources + [destinationRoot]
        let scopes = startSecurityScopedAccess(for: allDirectories)
        defer { stopSecurityScopedAccess(scopes) }

        let destinationDirectory = destinationRoot.url
            .appendingPathComponent(destinationFolderName, isDirectory: true)
            .standardizedFileURL

        do {
            try FileManager.default.createDirectory(
                at: destinationDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            failures.append(BWLegacyBudgetMigrationFailure(
                location: location,
                sourceURL: destinationRoot.url,
                message: error.localizedDescription
            ))
            return
        }

        var migratedSourceURLs = Set<URL>()

        for source in uniqueDirectories(sources) {
            let sourceDirectory = source.url.standardizedFileURL

            guard sourceDirectory != destinationDirectory,
                  FileManager.default.fileExists(atPath: sourceDirectory.path)
            else {
                continue
            }

            let sourceFiles: [URL]
            do {
                sourceFiles = try FileManager.default.contentsOfDirectory(
                    at: sourceDirectory,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles]
                )
                .filter(isBudgetFile)
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            } catch {
                failures.append(BWLegacyBudgetMigrationFailure(
                    location: location,
                    sourceURL: sourceDirectory,
                    message: error.localizedDescription
                ))
                continue
            }

            for sourceFile in sourceFiles {
                let standardizedSource = sourceFile.standardizedFileURL
                guard migratedSourceURLs.insert(standardizedSource).inserted else {
                    continue
                }

                do {
                    let result = try moveBudgetFile(
                        standardizedSource,
                        to: destinationDirectory
                    )
                    entries.append(BWLegacyBudgetMigrationEntry(
                        location: location,
                        sourceURL: standardizedSource,
                        destinationURL: result.url,
                        outcome: result.outcome
                    ))
                } catch {
                    failures.append(BWLegacyBudgetMigrationFailure(
                        location: location,
                        sourceURL: standardizedSource,
                        message: error.localizedDescription
                    ))
                }
            }
        }
    }

    private static func moveBudgetFile(
        _ sourceURL: URL,
        to destinationDirectory: URL
    ) throws -> (url: URL, outcome: BWLegacyBudgetMigrationOutcome) {
        let originalDestination = destinationDirectory
            .appendingPathComponent(sourceURL.lastPathComponent)
            .standardizedFileURL

        if FileManager.default.fileExists(atPath: originalDestination.path),
           try coordinatedFilesAreIdentical(sourceURL, originalDestination) {
            try coordinatedRemove(sourceURL)
            return (originalDestination, .alreadyPresent)
        }

        let destinationURL = uniqueDestinationURL(
            preferredURL: originalDestination,
            in: destinationDirectory
        )
        let temporaryURL = destinationDirectory
            .appendingPathComponent(".\(UUID().uuidString).migration")

        do {
            try coordinatedCopy(
                sourceURL,
                temporaryURL: temporaryURL,
                destinationURL: destinationURL,
                destinationDirectory: destinationDirectory
            )
            try coordinatedRemove(sourceURL)
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }

        return (
            destinationURL,
            destinationURL.lastPathComponent == originalDestination.lastPathComponent
                ? .moved
                : .renamed
        )
    }

    private static func coordinatedFilesAreIdentical(_ firstURL: URL, _ secondURL: URL) throws -> Bool {
        try coordinatedData(at: firstURL) == coordinatedData(at: secondURL)
    }

    private static func coordinatedData(at url: URL) throws -> Data {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var operationResult: Result<Data, Error> = .success(Data())

        coordinator.coordinate(
            readingItemAt: url,
            options: [.withoutChanges],
            error: &coordinationError
        ) { coordinatedURL in
            operationResult = Result {
                try Data(contentsOf: coordinatedURL)
            }
        }

        if let coordinationError {
            throw coordinationError
        }
        return try operationResult.get()
    }

    private static func coordinatedCopy(
        _ sourceURL: URL,
        temporaryURL: URL,
        destinationURL: URL,
        destinationDirectory: URL
    ) throws {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var operationResult: Result<Void, Error> = .success(())

        coordinator.coordinate(
            readingItemAt: sourceURL,
            options: [.withoutChanges],
            writingItemAt: destinationDirectory,
            options: [],
            error: &coordinationError
        ) { coordinatedSourceURL, coordinatedDestinationDirectory in
            operationResult = Result {
                let coordinatedTemporaryURL = coordinatedDestinationDirectory
                    .appendingPathComponent(temporaryURL.lastPathComponent)
                let coordinatedDestinationURL = coordinatedDestinationDirectory
                    .appendingPathComponent(destinationURL.lastPathComponent)

                try FileManager.default.copyItem(
                    at: coordinatedSourceURL,
                    to: coordinatedTemporaryURL
                )
                try FileManager.default.moveItem(
                    at: coordinatedTemporaryURL,
                    to: coordinatedDestinationURL
                )
            }
        }

        if let coordinationError {
            throw coordinationError
        }
        try operationResult.get()
    }

    private static func coordinatedRemove(_ url: URL) throws {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var operationResult: Result<Void, Error> = .success(())

        coordinator.coordinate(
            writingItemAt: url,
            options: [.forDeleting],
            error: &coordinationError
        ) { coordinatedURL in
            operationResult = Result {
                try FileManager.default.removeItem(at: coordinatedURL)
            }
        }

        if let coordinationError {
            throw coordinationError
        }
        try operationResult.get()
    }

    private static func uniqueDestinationURL(
        preferredURL: URL,
        in destinationDirectory: URL
    ) -> URL {
        guard FileManager.default.fileExists(atPath: preferredURL.path) else {
            return preferredURL
        }

        let baseName = preferredURL.deletingPathExtension().lastPathComponent
        let fileExtension = preferredURL.pathExtension
        var index = 2

        while true {
            let fileName = "\(baseName) \(index)"
            let candidate = destinationDirectory
                .appendingPathComponent(fileName)
                .appendingPathExtension(fileExtension)

            if !FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }

            index += 1
        }
    }

    private static func uniqueDirectories(
        _ directories: [BWLegacyBudgetDirectory]
    ) -> [BWLegacyBudgetDirectory] {
        var seen = Set<URL>()
        return directories.filter {
            seen.insert($0.url.standardizedFileURL).inserted
        }
    }

    private static func isBudgetFile(_ url: URL) -> Bool {
        guard url.pathExtension.lowercased() == "budget" else {
            return false
        }

        return (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) != false
    }

    private static func startSecurityScopedAccess(
        for directories: [BWLegacyBudgetDirectory]
    ) -> [URL] {
        var seen = Set<URL>()
        var accessed: [URL] = []

        for rootURL in directories.compactMap(\.securityScopedRootURL) {
            let standardizedURL = rootURL.standardizedFileURL
            guard seen.insert(standardizedURL).inserted else {
                continue
            }

            if standardizedURL.startAccessingSecurityScopedResource() {
                accessed.append(standardizedURL)
            }
        }

        return accessed
    }

    private static func stopSecurityScopedAccess(_ urls: [URL]) {
        urls.forEach { $0.stopAccessingSecurityScopedResource() }
    }
}
