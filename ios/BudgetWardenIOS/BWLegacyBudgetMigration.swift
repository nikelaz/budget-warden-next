/*
 * Budget Warden
 * Copyright (c) 2026 Lazarov & Co EOOD
 * Author: Nikola Lazarov
 *
 * Licensed under the Source-Available Educational License.
 * See the LICENSE file in the project root for full terms.
 */

import BWAppleCore
import Foundation

private enum BWLegacyMigrationDefaults {
    static let localVaultBookmark = "BWI_LOCAL_VAULT_BOOKMARK"
    static let localComplete = "BWI_LEGACY_LOCAL_MIGRATION_COMPLETE_V1"
    static let iCloudComplete = "BWI_LEGACY_ICLOUD_MIGRATION_COMPLETE_V1"
}

private enum BWLegacyMigrationConstants {
    static let legacyFolderName = "Budget Warden Vaults"
    static let iCloudContainerIdentifier = "iCloud.com.lazarovco.BudgetWarden"
}

@MainActor
extension BWStore {
    func migrateLegacyBudgetsIfNeeded() async {
        guard !hasAttemptedLegacyMigration else {
            return
        }
        hasAttemptedLegacyMigration = true

        let defaults = UserDefaults.standard
        let documentsRoot = localDocumentsRoot()
        let localSources = legacyLocalSources(documentsRoot: documentsRoot)
        let iCloudDocumentsRoot = await legacyICloudDocumentsRoot()
        let iCloudSources = iCloudDocumentsRoot.map {
            [BWLegacyBudgetDirectory(
                url: $0.url.appendingPathComponent(
                    BWLegacyMigrationConstants.legacyFolderName,
                    isDirectory: true
                )
            )]
        } ?? []

        let hasLegacyLocalBudgets = await BWLegacyBudgetMigrator.containsBudgetFiles(
            in: localSources
        )
        let hasLegacyICloudBudgets = await BWLegacyBudgetMigrator.containsBudgetFiles(
            in: iCloudSources
        )
        let shouldMigrateLocal = documentsRoot != nil && !defaults.bool(
            forKey: BWLegacyMigrationDefaults.localComplete
        ) && hasLegacyLocalBudgets
        let shouldMigrateICloud = iCloudDocumentsRoot != nil && !defaults.bool(
            forKey: BWLegacyMigrationDefaults.iCloudComplete
        ) && hasLegacyICloudBudgets

        guard shouldMigrateLocal || shouldMigrateICloud else {
            return
        }

        let report = await BWLegacyBudgetMigrator.migrate(
            BWLegacyBudgetMigrationRequest(
                localSources: shouldMigrateLocal ? localSources : [],
                localDocumentsRoot: shouldMigrateLocal ? documentsRoot : nil,
                iCloudSources: shouldMigrateICloud ? iCloudSources : [],
                iCloudDriveRoot: shouldMigrateICloud ? iCloudDocumentsRoot : nil
            )
        )

        if shouldMigrateLocal, report.isComplete(for: .local) {
            defaults.set(true, forKey: BWLegacyMigrationDefaults.localComplete)
        }
        if shouldMigrateICloud, report.isComplete(for: .iCloud) {
            defaults.set(true, forKey: BWLegacyMigrationDefaults.iCloudComplete)
        }

        remapRecentFiles(using: report.entries)

        if !report.failures.isEmpty {
            let details = report.failures
                .prefix(3)
                .map { "\($0.sourceURL.lastPathComponent): \($0.message)" }
                .joined(separator: "\n")
            let suffix = report.failures.count > 3
                ? "\nAnd \(report.failures.count - 3) more."
                : ""
            errorMessage = """
                Some legacy budgets could not be migrated. They will be retried the next time the app starts.

                \(details)\(suffix)
                """
        }
    }

    private func localDocumentsRoot() -> BWLegacyBudgetDirectory? {
        guard let documentsURL = try? FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else {
            return nil
        }

        return BWLegacyBudgetDirectory(url: documentsURL)
    }

    private func legacyLocalSources(
        documentsRoot: BWLegacyBudgetDirectory?
    ) -> [BWLegacyBudgetDirectory] {
        var sources: [BWLegacyBudgetDirectory] = []

        if let bookmarkedVault = resolveLegacyBookmark(
            key: BWLegacyMigrationDefaults.localVaultBookmark
        ) {
            sources.append(BWLegacyBudgetDirectory(
                url: bookmarkedVault,
                securityScopedRootURL: bookmarkedVault
            ))
        }

        if let documentsRoot {
            sources.append(BWLegacyBudgetDirectory(
                url: documentsRoot.url.appendingPathComponent(
                    BWLegacyMigrationConstants.legacyFolderName,
                    isDirectory: true
                )
            ))
        }

        return sources
    }

    private func legacyICloudDocumentsRoot() async -> BWLegacyBudgetDirectory? {
        let containerIdentifier = BWLegacyMigrationConstants.iCloudContainerIdentifier
        let containerURL = await Task.detached(priority: .utility) {
            FileManager.default.url(
                forUbiquityContainerIdentifier: containerIdentifier
            )
        }.value

        return containerURL.map {
            BWLegacyBudgetDirectory(
                url: $0.appendingPathComponent("Documents", isDirectory: true)
            )
        }
    }

    private func resolveLegacyBookmark(key: String) -> URL? {
        guard let data = UserDefaults.standard.data(forKey: key) else {
            return nil
        }

        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: [.withoutUI, .withoutImplicitStartAccessing],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            return nil
        }

        if isStale, let refreshed = try? url.bookmarkData(options: []) {
            UserDefaults.standard.set(refreshed, forKey: key)
        }

        return url.standardizedFileURL
    }
}
