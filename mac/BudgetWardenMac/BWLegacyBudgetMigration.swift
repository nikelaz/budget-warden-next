/*
 * Budget Warden
 * Copyright (c) 2026 Lazarov & Co EOOD
 * Author: Nikola Lazarov
 *
 * Licensed under the Source-Available Educational License.
 * See the LICENSE file in the project root for full terms.
 */

import AppKit
import BWAppleCore
import Darwin
import Foundation

private enum BWLegacyMigrationDefaults {
    static let vaultLocation = "BW_VAULT_LOCATION"
    static let localVaultBookmark = "BW_LOCAL_VAULT_BOOKMARK"
    static let legacyVaultBookmark = "BW_VAULT_BOOKMARK"
    static let iCloudVaultBookmark = "BW_ICLOUD_VAULT_BOOKMARK"

    static let documentsRootBookmark = "BW_LEGACY_MIGRATION_DOCUMENTS_ROOT_V1"
    static let iCloudDriveRootBookmark = "BW_LEGACY_MIGRATION_ICLOUD_ROOT_V1"
    static let localComplete = "BW_LEGACY_LOCAL_MIGRATION_COMPLETE_V1"
    static let iCloudComplete = "BW_LEGACY_ICLOUD_MIGRATION_COMPLETE_V1"
}

private enum BWLegacyMigrationConstants {
    static let legacyFolderName = "Budget Warden Vaults"
    static let iCloudContainerIdentifier = "iCloud.com.lazarovco.BudgetWarden"
}

@MainActor
extension BWStore {
    func migrateLegacyBudgetsIfNeeded(windowStore: BWWindowStore) async {
        guard !hasAttemptedLegacyMigration else {
            return
        }
        hasAttemptedLegacyMigration = true

        let defaults = UserDefaults.standard
        var localSources = legacyLocalSources()
        var iCloudSources = await legacyICloudSources()

        let hasLegacyLocalBudgets = await BWLegacyBudgetMigrator.containsBudgetFiles(
            in: localSources
        )
        let hasLegacyICloudState = await shouldAttemptLegacyICloudMigration(
            sources: iCloudSources
        )
        let shouldMigrateLocal = !defaults.bool(
            forKey: BWLegacyMigrationDefaults.localComplete
        ) && hasLegacyLocalBudgets
        let shouldMigrateICloud = !defaults.bool(
            forKey: BWLegacyMigrationDefaults.iCloudComplete
        ) && hasLegacyICloudState

        var documentsRoot: BWLegacyBudgetDirectory?
        if shouldMigrateLocal {
            documentsRoot = authorizedRoot(
                bookmarkKey: BWLegacyMigrationDefaults.documentsRootBookmark,
                expectedURL: visibleDocumentsURL
            ) ?? requestRootAccess(
                title: "Allow Budget Migration",
                message: "Select your Documents folder so Budget Warden can move your existing budgets into Documents/Budgets.",
                prompt: "Select Documents",
                expectedURL: visibleDocumentsURL,
                bookmarkKey: BWLegacyMigrationDefaults.documentsRootBookmark,
                windowStore: windowStore
            )

            if let documentsRoot {
                localSources.append(BWLegacyBudgetDirectory(
                    url: documentsRoot.url.appendingPathComponent(
                        BWLegacyMigrationConstants.legacyFolderName,
                        isDirectory: true
                    ),
                    securityScopedRootURL: documentsRoot.url
                ))
            }
        }

        var iCloudDriveRoot: BWLegacyBudgetDirectory?
        if shouldMigrateICloud, FileManager.default.ubiquityIdentityToken != nil {
            iCloudDriveRoot = authorizedRoot(
                bookmarkKey: BWLegacyMigrationDefaults.iCloudDriveRootBookmark,
                expectedURL: visibleICloudDriveURL
            ) ?? requestRootAccess(
                title: "Allow iCloud Budget Migration",
                message: "Select iCloud Drive so Budget Warden can move your existing budgets into iCloud Drive/Budgets.",
                prompt: "Select iCloud Drive",
                expectedURL: visibleICloudDriveURL,
                bookmarkKey: BWLegacyMigrationDefaults.iCloudDriveRootBookmark,
                windowStore: windowStore
            )

            if let iCloudDriveRoot {
                iCloudSources.append(BWLegacyBudgetDirectory(
                    url: iCloudDriveRoot.url.appendingPathComponent(
                        BWLegacyMigrationConstants.legacyFolderName,
                        isDirectory: true
                    ),
                    securityScopedRootURL: iCloudDriveRoot.url
                ))
            }
        }

        guard documentsRoot != nil || iCloudDriveRoot != nil else {
            return
        }

        let report = await BWLegacyBudgetMigrator.migrate(
            BWLegacyBudgetMigrationRequest(
                localSources: localSources,
                localDocumentsRoot: documentsRoot,
                iCloudSources: iCloudSources,
                iCloudDriveRoot: iCloudDriveRoot
            )
        )

        if documentsRoot != nil, report.isComplete(for: .local) {
            defaults.set(true, forKey: BWLegacyMigrationDefaults.localComplete)
        }
        if iCloudDriveRoot != nil, report.isComplete(for: .iCloud) {
            defaults.set(true, forKey: BWLegacyMigrationDefaults.iCloudComplete)
        }

        remapRecentBudgets(using: report.entries)

        if !report.failures.isEmpty {
            let details = report.failures
                .prefix(3)
                .map { "\($0.sourceURL.lastPathComponent): \($0.message)" }
                .joined(separator: "\n")
            let suffix = report.failures.count > 3
                ? "\nAnd \(report.failures.count - 3) more."
                : ""
            windowStore.setError(BWError.validation(
                "Some legacy budgets could not be migrated. They will be retried the next time the app starts.\n\n\(details)\(suffix)"
            ))
        }
    }

    private func legacyLocalSources() -> [BWLegacyBudgetDirectory] {
        var sources: [BWLegacyBudgetDirectory] = []

        if let bookmarkedVault = resolveSecurityScopedBookmark(
            keys: [
                BWLegacyMigrationDefaults.localVaultBookmark,
                BWLegacyMigrationDefaults.legacyVaultBookmark
            ]
        ) {
            sources.append(BWLegacyBudgetDirectory(
                url: bookmarkedVault,
                securityScopedRootURL: bookmarkedVault
            ))
        }

        if let sandboxDocuments = try? FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ) {
            sources.append(BWLegacyBudgetDirectory(
                url: sandboxDocuments.appendingPathComponent(
                    BWLegacyMigrationConstants.legacyFolderName,
                    isDirectory: true
                )
            ))
        }

        if let authorizedDocuments = authorizedRoot(
            bookmarkKey: BWLegacyMigrationDefaults.documentsRootBookmark,
            expectedURL: visibleDocumentsURL
        ) {
            sources.append(BWLegacyBudgetDirectory(
                url: authorizedDocuments.url.appendingPathComponent(
                    BWLegacyMigrationConstants.legacyFolderName,
                    isDirectory: true
                ),
                securityScopedRootURL: authorizedDocuments.url
            ))
        }

        return sources
    }

    private func legacyICloudSources() async -> [BWLegacyBudgetDirectory] {
        var sources: [BWLegacyBudgetDirectory] = []

        if let bookmarkedVault = resolveSecurityScopedBookmark(
            keys: [BWLegacyMigrationDefaults.iCloudVaultBookmark]
        ) {
            sources.append(BWLegacyBudgetDirectory(
                url: bookmarkedVault,
                securityScopedRootURL: bookmarkedVault
            ))
        }

        let containerIdentifier = BWLegacyMigrationConstants.iCloudContainerIdentifier
        let containerURL = await Task.detached(priority: .utility) {
            FileManager.default.url(
                forUbiquityContainerIdentifier: containerIdentifier
            )
        }.value

        if let containerURL {
            sources.append(BWLegacyBudgetDirectory(
                url: containerURL
                    .appendingPathComponent("Documents", isDirectory: true)
                    .appendingPathComponent(
                        BWLegacyMigrationConstants.legacyFolderName,
                        isDirectory: true
                    )
            ))
        }

        if let authorizedICloudDrive = authorizedRoot(
            bookmarkKey: BWLegacyMigrationDefaults.iCloudDriveRootBookmark,
            expectedURL: visibleICloudDriveURL
        ) {
            sources.append(BWLegacyBudgetDirectory(
                url: authorizedICloudDrive.url.appendingPathComponent(
                    BWLegacyMigrationConstants.legacyFolderName,
                    isDirectory: true
                ),
                securityScopedRootURL: authorizedICloudDrive.url
            ))
        }

        return sources
    }

    private func shouldAttemptLegacyICloudMigration(
        sources: [BWLegacyBudgetDirectory]
    ) async -> Bool {
        if await BWLegacyBudgetMigrator.containsBudgetFiles(in: sources) {
            return true
        }

        let defaults = UserDefaults.standard
        if defaults.string(forKey: BWLegacyMigrationDefaults.vaultLocation) == "iCloud" {
            return true
        }

        return FileManager.default.fileExists(
            atPath: visibleICloudDriveURL
                .appendingPathComponent(
                    BWLegacyMigrationConstants.legacyFolderName,
                    isDirectory: true
                )
                .path
        )
    }

    private func requestRootAccess(
        title: String,
        message: String,
        prompt: String,
        expectedURL: URL,
        bookmarkKey: String,
        windowStore: BWWindowStore
    ) -> BWLegacyBudgetDirectory? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.message = message
        panel.prompt = prompt
        panel.directoryURL = expectedURL
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let selectedURL = panel.url else {
            return nil
        }

        guard pathsReferToSameDirectory(selectedURL, expectedURL) else {
            windowStore.setError(BWError.validation(
                "Select \(expectedURL.path) to continue the legacy budget migration."
            ))
            return nil
        }

        do {
            let bookmark = try selectedURL.bookmarkData(options: [.withSecurityScope])
            UserDefaults.standard.set(bookmark, forKey: bookmarkKey)
            return BWLegacyBudgetDirectory(
                url: selectedURL.standardizedFileURL,
                securityScopedRootURL: selectedURL.standardizedFileURL
            )
        } catch {
            windowStore.setError(BWError.validation(
                "Budget Warden could not save access to \(selectedURL.path): \(error.localizedDescription)"
            ))
            return nil
        }
    }

    private func authorizedRoot(
        bookmarkKey: String,
        expectedURL: URL
    ) -> BWLegacyBudgetDirectory? {
        guard let url = resolveSecurityScopedBookmark(keys: [bookmarkKey]),
              pathsReferToSameDirectory(url, expectedURL)
        else {
            return nil
        }

        return BWLegacyBudgetDirectory(url: url, securityScopedRootURL: url)
    }

    private func resolveSecurityScopedBookmark(keys: [String]) -> URL? {
        let defaults = UserDefaults.standard

        for key in keys {
            guard let data = defaults.data(forKey: key) else {
                continue
            }

            do {
                var isStale = false
                let url = try URL(
                    resolvingBookmarkData: data,
                    options: [.withSecurityScope],
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )

                if isStale {
                    let refreshed = try url.bookmarkData(options: [.withSecurityScope])
                    defaults.set(refreshed, forKey: key)
                }

                return url.standardizedFileURL
            } catch {
                continue
            }
        }

        return nil
    }

    private func remapRecentBudgets(using entries: [BWLegacyBudgetMigrationEntry]) {
        let mappings = Dictionary(
            entries.map {
                ($0.sourceURL.standardizedFileURL, $0.destinationURL.standardizedFileURL)
            },
            uniquingKeysWith: { _, latest in latest }
        )
        guard !mappings.isEmpty else {
            return
        }

        let documentController = NSDocumentController.shared
        var seen = Set<URL>()
        let migrated = entries.compactMap { entry -> URL? in
            let url = entry.destinationURL.standardizedFileURL
            return seen.insert(url).inserted ? url : nil
        }
        let remappedExisting = documentController.recentDocumentURLs.compactMap { recentURL -> URL? in
            let url = mappings[recentURL.standardizedFileURL] ?? recentURL.standardizedFileURL
            return seen.insert(url).inserted ? url : nil
        }
        let updatedRecents = migrated + remappedExisting

        documentController.clearRecentDocuments(nil)
        for url in updatedRecents.reversed() {
            documentController.noteNewRecentDocumentURL(url)
        }
        recentFiles = documentController.recentDocumentURLs
    }

    private func pathsReferToSameDirectory(_ firstURL: URL, _ secondURL: URL) -> Bool {
        firstURL.resolvingSymlinksInPath().standardizedFileURL
            == secondURL.resolvingSymlinksInPath().standardizedFileURL
    }

    private var visibleDocumentsURL: URL {
        userHomeDirectoryURL
            .appendingPathComponent("Documents", isDirectory: true)
    }

    private var visibleICloudDriveURL: URL {
        userHomeDirectoryURL
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Mobile Documents", isDirectory: true)
            .appendingPathComponent("com~apple~CloudDocs", isDirectory: true)
    }

    /// Foundation's home-directory APIs are redirected into the app container
    /// for a sandboxed process. The POSIX account record retains the visible
    /// home path needed to validate user-selected folders.
    private var userHomeDirectoryURL: URL {
        guard let account = getpwuid(getuid()) else {
            return FileManager.default.homeDirectoryForCurrentUser
        }

        return URL(
            fileURLWithPath: String(cString: account.pointee.pw_dir),
            isDirectory: true
        )
    }
}
