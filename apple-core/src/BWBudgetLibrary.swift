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

/// A change the library made to a budget file, reported on the main actor so
/// the app can reload an open budget, sync it, or update its recent list.
public enum BWBudgetLibraryEvent: Sendable {
    /// The budget file at the URL was saved.
    case changed(URL)
    /// A new budget file was created at the URL.
    case created(URL)
    /// The budget file at the URL was deleted.
    case deleted(URL)
}

/// File-level access to the budgets an Apple app can reach, shared by the
/// MCP server and App Intents so both read, merge, and save budgets the same
/// way the app does, without changing which budget the app has open.
///
/// Parsed budgets are cached per file and reused while the file's
/// modification date and size are unchanged, so listing budgets or resolving
/// a Shortcuts entity does not decode every recent budget each time.
public final class BWBudgetLibrary: @unchecked Sendable {
    private struct CachedBudget {
        let modificationDate: Date?
        let size: Int?
        let budget: BWBudget
    }

    private let lock = NSLock()
    private var openURL: URL?
    private var recentURLs: [URL] = []
    private var createdURLs: [URL] = []
    private var defaultCurrency = BWCurrency.defaultCurrency.rawValue
    private var cache: [String: CachedBudget] = [:]
    private let newBudgetDirectory: @Sendable () -> URL?
    private let notify: @Sendable (BWBudgetLibraryEvent) -> Void

    /// - Parameters:
    ///   - newBudgetDirectory: Folder for budgets created outside the app's
    ///     own UI, by MCP clients or Shortcuts. Called off the main thread.
    ///   - events: Receives the library's changes on the main actor.
    public init(
        newBudgetDirectory: @escaping @Sendable () -> URL?,
        events: @escaping @MainActor @Sendable (BWBudgetLibraryEvent) -> Void
    ) {
        self.newBudgetDirectory = newBudgetDirectory
        notify = { event in
            Task { @MainActor in events(event) }
        }
    }

    // MARK: Reachable budgets

    /// Shares the budgets the app can currently reach. Keep the URLs the app
    /// resolved itself so their security scope remains usable.
    public func update(open: URL?, recent: [URL], defaultCurrencyCode: String) {
        lock.withLock {
            openURL = open
            recentURLs = recent
            defaultCurrency = defaultCurrencyCode
            // Created budgets stay reachable until the app lists them itself.
            let shared = Set(([open].compactMap { $0 } + recent).map(Self.location))
            createdURLs.removeAll { shared.contains(Self.location($0)) }
            // Forget budgets the app no longer lists.
            let known = Set(knownURLsLocked().map(Self.location))
            cache = cache.filter { known.contains($0.key) }
        }
    }

    /// The currency for new budgets and for budgets saved before budgets
    /// stored one.
    public var defaultCurrencyCode: String {
        lock.withLock { defaultCurrency }
    }

    /// The budget open in the app, followed by recent and newly created budgets.
    public var knownURLs: [URL] {
        lock.withLock { knownURLsLocked() }
    }

    public func isOpen(_ url: URL) -> Bool {
        lock.withLock { openURL.map(Self.location) == Self.location(url) }
    }

    /// The URL the app shared for a location, so its security scope is kept.
    public func knownURL(location: String) -> URL? {
        lock.withLock { knownURLsLocked().first { Self.location($0) == location } }
    }

    // MARK: Reading

    /// The budget stored at `url`, from the cache when the file is unchanged.
    public func budget(at url: URL) throws -> BWBudget {
        try withAccess(to: url) {
            let key = Self.location(url)
            let attributes = Self.attributes(of: url)
            if let cached = lock.withLock({ cache[key] }),
               cached.modificationDate == attributes.modificationDate,
               cached.size == attributes.size {
                return cached.budget
            }
            let budget = try readFresh(at: url)
            store(budget, for: url)
            return budget
        }
    }

    /// The budget's currency, or the default for budgets without one.
    public func currencyCode(of budget: BWBudget) -> String {
        budgetCurrencyCode(budget: budget, defaultCurrency: defaultCurrencyCode)
    }

    /// The raw JSON stored at `url`.
    public func json(at url: URL) throws -> String {
        try withAccess(to: url) {
            guard let json = String(data: try BWCoordinatedFile.read(url), encoding: .utf8) else {
                throw FfiError(message: "\(url.lastPathComponent) is not UTF-8 text.")
            }
            return json
        }
    }

    // MARK: Writing

    /// Applies `operation` to the budget currently stored at `url`, merges
    /// the result with the stored copy, and saves it, under the same lock as
    /// the app's own saves.
    @discardableResult
    public func mutate(at url: URL, _ operation: (BWBudget) throws -> BWBudget) throws -> BWBudget {
        let saved = try withAccess(to: url) {
            try BWBudgetSaveLock.withLock {
                let stored = try readFresh(at: url)
                var changed = try operation(stored).updateActuals()
                changed.url = stored.url
                var merged = try mergeBudgetForSave(budgetInMemory: changed, budgetOnDisk: stored)
                    .updateActuals()
                merged.url = stored.url
                try BWCoordinatedFile.write(Data(encodeBudget(budget: merged).utf8), to: url)
                store(merged, for: url)
                return merged
            }
        }
        notify(.changed(url))
        return saved
    }

    /// Replaces the JSON stored at `url`. When `expectedRevisionID` is set
    /// and the stored budget has another revision, nothing is written and
    /// this returns `false`.
    public func write(json: String, to url: URL, expectedRevisionID: UUID?) throws -> Bool {
        try withAccess(to: url) {
            try BWBudgetSaveLock.withLock {
                if let expectedRevisionID {
                    let stored = try decodeBudget(
                        json: String(decoding: BWCoordinatedFile.read(url), as: UTF8.self),
                        url: url.path
                    )
                    // Another writer saved since the caller read the budget.
                    guard stored.revisionId == expectedRevisionID else {
                        return false
                    }
                }
                try BWCoordinatedFile.write(Data(json.utf8), to: url)
                return true
            }
        }
    }

    /// Writes a new budget into the folder for new budgets and returns its URL.
    public func create(_ budget: BWBudget, fileName: String) throws -> URL {
        try create(json: encodeBudget(budget: budget), fileName: fileName)
    }

    /// Writes new budget JSON into the folder for new budgets and returns its URL.
    public func create(json: String, fileName: String) throws -> URL {
        guard let directory = newBudgetDirectory() else {
            throw FfiError(message: "Budget Warden has no folder for new budgets.")
        }
        let url = Self.uniqueURL(in: directory, fileName: fileName)
        try reportingErrors {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try BWCoordinatedFile.write(Data(json.utf8), to: url, replacing: false)
        }
        lock.withLock { createdURLs.append(url) }
        notify(.created(url))
        return url
    }

    /// Deletes the budget file at `url`.
    public func delete(at url: URL) throws {
        try withAccess(to: url) {
            try BWBudgetSaveLock.withLock {
                try BWCoordinatedFile.delete(url)
            }
        }
        lock.withLock {
            let location = Self.location(url)
            cache[location] = nil
            createdURLs.removeAll { Self.location($0) == location }
        }
        notify(.deleted(url))
    }

    /// Reports a change made to `url` by someone else, such as the MCP server.
    public func didChange(_ url: URL) {
        notify(.changed(url))
    }

    // MARK: Helpers

    public static func location(_ url: URL) -> String {
        url.standardizedFileURL.path
    }

    public static func uniqueURL(in directory: URL, fileName: String) -> URL {
        let candidate = directory.appendingPathComponent(fileName, isDirectory: false)
        guard FileManager.default.fileExists(atPath: candidate.path) else {
            return candidate
        }
        let stem = (fileName as NSString).deletingPathExtension
        var index = 2
        while true {
            let url = directory.appendingPathComponent("\(stem) \(index).budget", isDirectory: false)
            if !FileManager.default.fileExists(atPath: url.path) {
                return url
            }
            index += 1
        }
    }

    // Must be called while holding the lock.
    private func knownURLsLocked() -> [URL] {
        var seen = Set<String>()
        return ([openURL].compactMap { $0 } + recentURLs + createdURLs).filter {
            seen.insert(Self.location($0)).inserted
        }
    }

    /// Reads and decodes `url`, writing back budgets migrated from the legacy
    /// format the same way the apps do.
    private func readFresh(at url: URL) throws -> BWBudget {
        try reportingErrors {
            var budget = try BWCoordinatedFile.readBudget(url)
            // TEMPORARY LEGACY MIGRATION: mirror the apps' schema-v1 writeback.
            if budget.requiresMigrationWriteback {
                try BWCoordinatedFile.write(Data(encodeBudget(budget: budget).utf8), to: url)
                budget.requiresMigrationWriteback = false
            }
            return try budget.updateActuals()
        }
    }

    private func store(_ budget: BWBudget, for url: URL) {
        let attributes = Self.attributes(of: url)
        lock.withLock {
            cache[Self.location(url)] = CachedBudget(
                modificationDate: attributes.modificationDate,
                size: attributes.size,
                budget: budget
            )
        }
    }

    private static func attributes(of url: URL) -> (modificationDate: Date?, size: Int?) {
        var url = url
        url.removeAllCachedResourceValues()
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        return (values?.contentModificationDate, values?.fileSize)
    }

    private func withAccess<T>(to url: URL, _ operation: () throws -> T) throws -> T {
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped {
                url.stopAccessingSecurityScopedResource()
            }
        }
        return try reportingErrors(operation)
    }

    /// Converts Foundation errors into readable messages.
    private func reportingErrors<T>(_ operation: () throws -> T) throws -> T {
        do {
            return try operation()
        } catch let error as FfiError {
            throw error
        } catch {
            throw FfiError(message: error.localizedDescription)
        }
    }
}

/// Forwards library events to the app's store, which creates the library
/// before it can refer to itself.
@MainActor
public final class BWBudgetLibraryEventRelay {
    public var handler: ((BWBudgetLibraryEvent) -> Void)?

    public init() {}
}
