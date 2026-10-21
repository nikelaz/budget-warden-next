/*
 * Budget Warden
 * Copyright (c) 2026 Lazarov & Co EOOD
 * Author: Nikola Lazarov
 *
 * Licensed under the Source-Available Educational License.
 * See the LICENSE file in the project root for full terms.
 */

import BWCore
import Foundation
import Observation

/// A budget file in iCloud Drive.
public struct BWICloudBudget: Identifiable, Hashable, Sendable {
    public var url: URL
    public var title: String
    /// Other people have access through iCloud sharing.
    public var isShared: Bool
    /// Someone else owns the budget and shared it with the user.
    public var isSharedWithMe: Bool
    public var ownerName: String?
    public var isReadOnly: Bool
    public var isDownloaded: Bool
    public var modificationDate: Date?

    public var id: URL { url }

    /// "Shared by Ana", "iCloud Drive · Shared", or "iCloud Drive".
    public var locationDescription: String {
        if isSharedWithMe {
            let owner = "Shared by \(ownerName ?? "someone")"
            return isReadOnly ? "\(owner) · View only" : owner
        }
        return isShared ? "iCloud Drive · Shared" : "iCloud Drive"
    }
}

/// Budgets in the app's iCloud Drive folder and iCloud budgets that other
/// people shared with the user.
///
/// iCloud budgets are ordinary files that iCloud keeps in sync, so the app
/// opens and saves them like local ones. The library downloads them before
/// opening, merges conflicting iCloud versions with the CRDT instead of
/// letting one device's edits win, and reports when another device changed
/// the open budget. Share an iCloud budget by passing its URL to the system
/// share sheet (`ShareLink`), which offers iCloud collaboration.
@MainActor
@Observable
public final class BWICloudBudgetLibrary {
    /// The user is signed in to iCloud with iCloud Drive turned on.
    public private(set) var isAvailable = false
    public private(set) var budgets: [BWICloudBudget] = []
    /// `Documents` in the app's iCloud container: the "Budget Warden" folder
    /// in iCloud Drive.
    public private(set) var documentsURL: URL?

    @ObservationIgnored private var query: NSMetadataQuery?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var watchedURL: URL?
    @ObservationIgnored private var watchedModificationDate: Date?
    @ObservationIgnored private var sharedRecents: [BWICloudBudget] = []
    @ObservationIgnored private let budgetDidChange: @MainActor (URL) -> Void

    /// - Parameter budgetDidChange: iCloud delivered a change to the budget
    ///   passed to ``watch(_:)``.
    public init(budgetDidChange: @escaping @MainActor (URL) -> Void) {
        self.budgetDidChange = budgetDidChange
    }

    /// Finds the iCloud container and starts listing budgets.
    public func start() {
        guard query == nil else { return }
        guard FileManager.default.ubiquityIdentityToken != nil else {
            isAvailable = false
            return
        }
        Task {
            // Resolving the container can block while iCloud sets it up.
            let documents = await Task.detached(priority: .utility) {
                FileManager.default.url(forUbiquityContainerIdentifier: nil)?
                    .appendingPathComponent("Documents", isDirectory: true)
            }.value
            guard let documents else { return }
            try? FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
            documentsURL = documents
            isAvailable = true
            startQuery()
        }
    }

    private func startQuery() {
        let query = NSMetadataQuery()
        query.searchScopes = [
            NSMetadataQueryUbiquitousDocumentsScope,
            NSMetadataQueryAccessibleUbiquitousExternalDocumentsScope,
        ]
        query.predicate = NSPredicate(format: "%K LIKE[c] '*.budget'", NSMetadataItemFSNameKey)
        query.sortDescriptors = [NSSortDescriptor(key: NSMetadataItemFSContentChangeDateKey, ascending: false)]
        let center = NotificationCenter.default
        for name in [Notification.Name.NSMetadataQueryDidFinishGathering, .NSMetadataQueryDidUpdate] {
            observers.append(center.addObserver(forName: name, object: query, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.queryDidUpdate() }
            })
        }
        self.query = query
        query.start()
    }

    private func queryDidUpdate() {
        guard let query else { return }
        query.disableUpdates()
        defer { query.enableUpdates() }
        var found: [BWICloudBudget] = []
        for case let item as NSMetadataItem in query.results {
            guard let url = item.value(forAttribute: NSMetadataItemURLKey) as? URL else { continue }
            found.append(Self.budget(url: url, item: item))
        }
        let known = Set(found.map { $0.url.standardizedFileURL })
        budgets = found + sharedRecents.filter { !known.contains($0.url.standardizedFileURL) }

        if let watchedURL,
           let current = found.first(where: { $0.url.standardizedFileURL == watchedURL.standardizedFileURL }),
           current.isDownloaded,
           let modified = current.modificationDate,
           modified != watchedModificationDate {
            let isFirstObservation = watchedModificationDate == nil
            watchedModificationDate = modified
            if !isFirstObservation {
                _ = try? Self.resolveConflicts(at: watchedURL)
                budgetDidChange(watchedURL)
            }
        }
    }

    private static func budget(url: URL, item: NSMetadataItem) -> BWICloudBudget {
        let role = item.value(forAttribute: NSMetadataUbiquitousSharedItemCurrentUserRoleKey) as? String
        let permissions = item.value(forAttribute: NSMetadataUbiquitousSharedItemCurrentUserPermissionsKey) as? String
        let owner = item.value(forAttribute: NSMetadataUbiquitousSharedItemOwnerNameComponentsKey) as? PersonNameComponents
        let status = item.value(forAttribute: NSMetadataUbiquitousItemDownloadingStatusKey) as? String
        return BWICloudBudget(
            url: url,
            title: url.deletingPathExtension().lastPathComponent,
            isShared: (item.value(forAttribute: NSMetadataUbiquitousItemIsSharedKey) as? Bool) ?? false,
            isSharedWithMe: role == NSMetadataUbiquitousSharedItemRoleParticipant,
            ownerName: owner.map { PersonNameComponentsFormatter.localizedString(from: $0, style: .default) },
            isReadOnly: permissions == NSMetadataUbiquitousSharedItemPermissionsReadOnly,
            isDownloaded: status == NSMetadataUbiquitousItemDownloadingStatusCurrent,
            modificationDate: item.value(forAttribute: NSMetadataItemFSContentChangeDateKey) as? Date
        )
    }

    /// Adds iCloud budgets the user opened from a share link. iCloud has no
    /// API to list every item shared with a user, so shared budgets join the
    /// list once they have been opened (from the link, Files, or Finder).
    public func includeSharedBudgets(among urls: [URL]) {
        sharedRecents = urls.compactMap { url in
            let scoped = url.startAccessingSecurityScopedResource()
            defer {
                if scoped { url.stopAccessingSecurityScopedResource() }
            }
            guard let values = try? url.resourceValues(forKeys: [
                .isUbiquitousItemKey,
                .ubiquitousItemIsSharedKey,
                .ubiquitousSharedItemCurrentUserRoleKey,
                .ubiquitousSharedItemCurrentUserPermissionsKey,
                .ubiquitousSharedItemOwnerNameComponentsKey,
                .ubiquitousItemDownloadingStatusKey,
                .contentModificationDateKey,
            ]), values.isUbiquitousItem == true, values.ubiquitousItemIsShared == true else {
                return nil
            }
            return BWICloudBudget(
                url: url,
                title: url.deletingPathExtension().lastPathComponent,
                isShared: true,
                isSharedWithMe: values.ubiquitousSharedItemCurrentUserRole == .participant,
                ownerName: values.ubiquitousSharedItemOwnerNameComponents.map {
                    PersonNameComponentsFormatter.localizedString(from: $0, style: .default)
                },
                isReadOnly: values.ubiquitousSharedItemCurrentUserPermissions == .readOnly,
                isDownloaded: values.ubiquitousItemDownloadingStatus == .current,
                modificationDate: values.contentModificationDate
            )
        }
        queryDidUpdate()
        if query == nil {
            budgets = sharedRecents
        }
    }

    /// Whether `url` is listed as an iCloud budget.
    public func contains(_ url: URL) -> Bool {
        let target = url.standardizedFileURL
        if let documentsURL, target.path.hasPrefix(documentsURL.standardizedFileURL.path + "/") {
            return true
        }
        return budgets.contains { $0.url.standardizedFileURL == target }
    }

    /// Reports iCloud changes to `url` (the open budget) through
    /// `budgetDidChange`. Pass `nil` when no iCloud budget is open.
    public func watch(_ url: URL?) {
        guard watchedURL?.standardizedFileURL != url?.standardizedFileURL else { return }
        watchedURL = url
        watchedModificationDate = url.flatMap { url in
            budgets.first { $0.url.standardizedFileURL == url.standardizedFileURL }?.modificationDate
        }
    }

    /// Downloads an iCloud budget if needed and merges conflicting versions,
    /// so it is ready to open.
    public func prepareForOpening(_ url: URL) async throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped { url.stopAccessingSecurityScopedResource() }
        }
        let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
        guard values?.isUbiquitousItem == true else { return }
        if values?.ubiquitousItemDownloadingStatus != .current {
            try FileManager.default.startDownloadingUbiquitousItem(at: url)
            for _ in 0..<240 {
                try await Task.sleep(for: .milliseconds(250))
                var refreshed = url
                refreshed.removeAllCachedResourceValues()
                if (try? refreshed.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]))?
                    .ubiquitousItemDownloadingStatus == .current {
                    break
                }
            }
        }
        _ = try await Task.detached(priority: .userInitiated) {
            try Self.resolveConflicts(at: url)
        }.value
    }

    /// Writes a new budget into the app's iCloud Drive folder.
    public func createBudget(fileName: String, json: String) async throws -> URL {
        guard let documentsURL else {
            throw BWCloudError(message: "iCloud Drive is not available. Sign in to iCloud and turn on iCloud Drive.")
        }
        return try await Task.detached(priority: .userInitiated) {
            let url = BWMcpFileHost.uniqueURL(in: documentsURL, fileName: fileName)
            try BWCoordinatedFile.write(Data(json.utf8), to: url, replacing: false)
            return url
        }.value
    }

    /// Merges every unresolved iCloud conflict version of a budget into the
    /// current file. Returns whether there were conflicts.
    @discardableResult
    public nonisolated static func resolveConflicts(at url: URL) throws -> Bool {
        guard let conflicts = NSFileVersion.unresolvedConflictVersionsOfItem(at: url), !conflicts.isEmpty else {
            return false
        }
        try BWBudgetSaveLock.withLock {
            var merged = try BWCoordinatedFile.readBudget(url)
            for version in conflicts {
                guard let other = try? BWCoordinatedFile.readBudget(version.url, location: url),
                      other.id == merged.id else {
                    continue
                }
                merged = try mergeBudgetForSave(budgetInMemory: merged, budgetOnDisk: other).updateActuals()
            }
            try BWCoordinatedFile.write(Data(encodeBudget(budget: merged).utf8), to: url)
        }
        for version in conflicts {
            version.isResolved = true
        }
        try NSFileVersion.removeOtherVersionsOfItem(at: url)
        return true
    }
}
