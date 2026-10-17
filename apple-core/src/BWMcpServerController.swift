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

/// Held for the whole read-merge-write of every budget save, by the app and
/// by the MCP server, so neither can overwrite a save it never read.
public enum BWBudgetSaveLock {
    private static let lock = NSLock()

    public static func withLock<T>(_ body: () throws -> T) rethrows -> T {
        try lock.withLock(body)
    }
}

/// Persisted preferences for the built-in MCP server.
public struct BWMcpSettings: Equatable, Sendable {
    public var isEnabled: Bool
    public var allowsNetwork: Bool
    public var port: Int32
    public var token: String

    static func load(from defaults: UserDefaults, keyPrefix: String) -> BWMcpSettings {
        let storedPort = defaults.integer(forKey: keyPrefix + "PORT")
        var token = defaults.string(forKey: keyPrefix + "TOKEN") ?? ""
        if token.count < 16 {
            token = generateMcpToken()
            defaults.set(token, forKey: keyPrefix + "TOKEN")
        }
        return BWMcpSettings(
            isEnabled: defaults.bool(forKey: keyPrefix + "ENABLED"),
            allowsNetwork: defaults.bool(forKey: keyPrefix + "ALLOW_NETWORK"),
            // Zero selects the core's default port.
            port: Int32(clamping: max(storedPort, 0)),
            token: token
        )
    }

    func save(to defaults: UserDefaults, keyPrefix: String) {
        defaults.set(isEnabled, forKey: keyPrefix + "ENABLED")
        defaults.set(allowsNetwork, forKey: keyPrefix + "ALLOW_NETWORK")
        defaults.set(Int(port), forKey: keyPrefix + "PORT")
        defaults.set(token, forKey: keyPrefix + "TOKEN")
    }
}

/// Runs the core MCP server for an Apple app and gives it access to the app's
/// open and recent budgets.
@MainActor
public final class BWMcpServerController {
    public private(set) var settings: BWMcpSettings
    public private(set) var status: BWMcpServerStatus
    public private(set) var errorMessage: String?

    private let server = BWMcpServer()
    private let host: BWMcpFileHost
    private let keyPrefix: String

    /// - Parameters:
    ///   - keyPrefix: Prefix for the app's `UserDefaults` keys.
    ///   - newBudgetDirectory: Folder for budgets that MCP clients create.
    ///     Called off the main thread.
    ///   - budgetDidChange: The server saved the budget at a URL.
    ///   - budgetWasCreated: The server created a budget at a URL.
    ///   - showBudget: An MCP client asked the app to open a budget.
    public init(
        keyPrefix: String,
        newBudgetDirectory: @escaping @Sendable () -> URL?,
        budgetDidChange: @escaping @MainActor @Sendable (URL) -> Void,
        budgetWasCreated: @escaping @MainActor @Sendable (URL) -> Void,
        showBudget: @escaping @MainActor @Sendable (URL) -> Void
    ) {
        self.keyPrefix = keyPrefix
        settings = BWMcpSettings.load(from: .standard, keyPrefix: keyPrefix)
        status = BWMcpServerStatus(running: false, port: 0, url: nil, localUrl: nil)
        host = BWMcpFileHost(newBudgetDirectory: newBudgetDirectory) { event in
            Task { @MainActor in
                switch event {
                case .changed(let url): budgetDidChange(url)
                case .created(let url): budgetWasCreated(url)
                case .show(let url): showBudget(url)
                }
            }
        }
        apply()
    }

    /// Shares the budgets the app can currently reach. Keep the URLs the app
    /// resolved itself so their security scope remains usable.
    public func updateBudgets(open: URL?, recent: [URL], currencyCode: String) {
        host.update(open: open, recent: recent, currencyCode: currencyCode)
    }

    public func setEnabled(_ isEnabled: Bool) {
        change { $0.isEnabled = isEnabled }
    }

    public func setAllowsNetwork(_ allowsNetwork: Bool) {
        change { $0.allowsNetwork = allowsNetwork }
    }

    /// Replaces the secret in the server URL, disconnecting existing clients.
    public func regenerateURL() {
        change { $0.token = generateMcpToken() }
    }

    /// Restarts the server, for example after the app returns to the foreground.
    public func restartIfEnabled() {
        apply()
    }

    private func change(_ update: (inout BWMcpSettings) -> Void) {
        update(&settings)
        settings.save(to: .standard, keyPrefix: keyPrefix)
        apply()
    }

    private func apply() {
        errorMessage = nil
        guard settings.isEnabled else {
            server.stop()
            status = server.status()
            return
        }

        do {
            status = try server.start(
                host: host,
                config: BWMcpServerConfig(
                    port: settings.port,
                    token: settings.token,
                    allowNetwork: settings.allowsNetwork
                )
            )
        } catch let error as FfiError {
            errorMessage = error.message
            status = server.status()
        } catch {
            errorMessage = error.localizedDescription
            status = server.status()
        }
    }
}

enum BWMcpHostEvent: Sendable {
    case changed(URL)
    case created(URL)
    case show(URL)
}

/// Thread-safe file access for the MCP server. Locations are standardized file
/// paths of URLs the app shared, so the server can only reach those budgets.
final class BWMcpFileHost: BWMcpHost, @unchecked Sendable {
    private let lock = NSLock()
    private var openURL: URL?
    private var recentURLs: [URL] = []
    private var createdURLs: [URL] = []
    private var currency = "USD"
    private let newBudgetDirectory: @Sendable () -> URL?
    private let notify: @Sendable (BWMcpHostEvent) -> Void

    init(
        newBudgetDirectory: @escaping @Sendable () -> URL?,
        notify: @escaping @Sendable (BWMcpHostEvent) -> Void
    ) {
        self.newBudgetDirectory = newBudgetDirectory
        self.notify = notify
    }

    func update(open: URL?, recent: [URL], currencyCode: String) {
        lock.withLock {
            openURL = open
            recentURLs = recent
            currency = currencyCode
            // Created budgets stay reachable until the app lists them itself.
            let shared = Set(([open].compactMap { $0 } + recent).map(Self.location))
            createdURLs.removeAll { shared.contains(Self.location($0)) }
        }
    }

    func listBudgets() -> [BWMcpBudgetLocation] {
        lock.withLock {
            let openLocation = openURL.map(Self.location)
            return knownURLs().map { url in
                BWMcpBudgetLocation(
                    location: Self.location(url),
                    isOpen: Self.location(url) == openLocation
                )
            }
        }
    }

    func readBudgetFile(location: String) throws -> String {
        let url = try knownURL(location)
        return try withAccess(to: url) {
            let data = try coordinatedRead(at: url)
            guard let json = String(data: data, encoding: .utf8) else {
                throw FfiError(message: "\(url.lastPathComponent) is not UTF-8 text.")
            }
            return json
        }
    }

    func writeBudgetFile(location: String, json: String, expectedRevisionId: String?) throws -> Bool {
        let url = try knownURL(location)
        return try withAccess(to: url) {
            try BWBudgetSaveLock.withLock {
                if let expectedRevisionId {
                    let stored = try decodeBudget(
                        json: String(decoding: coordinatedRead(at: url), as: UTF8.self),
                        url: location
                    )
                    // Another writer saved since the server read the budget.
                    guard stored.revisionId == UUID(uuidString: expectedRevisionId) else {
                        return false
                    }
                }
                try coordinatedWrite(Data(json.utf8), to: url)
                return true
            }
        }
    }

    func createBudgetFile(fileName: String, json: String) throws -> String {
        guard let directory = newBudgetDirectory() else {
            throw FfiError(message: "Budget Warden has no folder for new budgets.")
        }
        let url = Self.uniqueURL(in: directory, fileName: fileName)
        try reportingErrors {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try coordinatedWrite(Data(json.utf8), to: url, replacing: false)
        }
        lock.withLock { createdURLs.append(url) }
        notify(.created(url))
        return Self.location(url)
    }

    func budgetDidChange(location: String) {
        if let url = try? knownURL(location) {
            notify(.changed(url))
        }
    }

    func showBudget(location: String) throws {
        notify(.show(try knownURL(location)))
    }

    func currencyCode() -> String {
        lock.withLock { currency }
    }

    // Must be called while holding the lock.
    private func knownURLs() -> [URL] {
        var seen = Set<String>()
        return ([openURL].compactMap { $0 } + recentURLs + createdURLs).filter {
            seen.insert(Self.location($0)).inserted
        }
    }

    private func knownURL(_ location: String) throws -> URL {
        let url = lock.withLock { knownURLs().first { Self.location($0) == location } }
        guard let url else {
            throw FfiError(message: "\(location) is not one of Budget Warden's budgets.")
        }
        return url
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

    /// Converts Foundation errors into readable messages for MCP clients.
    private func reportingErrors<T>(_ operation: () throws -> T) throws -> T {
        do {
            return try operation()
        } catch let error as FfiError {
            throw error
        } catch {
            throw FfiError(message: error.localizedDescription)
        }
    }

    private func coordinatedRead(at url: URL) throws -> Data {
        var coordinationError: NSError?
        var result: Result<Data, Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) {
            result = Result { try Data(contentsOf: $0) }
        }
        if let coordinationError {
            throw coordinationError
        }
        guard let result else {
            throw FfiError(message: "Could not read \(url.lastPathComponent).")
        }
        return try result.get()
    }

    private func coordinatedWrite(_ data: Data, to url: URL, replacing: Bool = true) throws {
        var coordinationError: NSError?
        var writeError: Error?
        NSFileCoordinator().coordinate(
            writingItemAt: url,
            options: replacing ? .forReplacing : [],
            error: &coordinationError
        ) { coordinatedURL in
            do {
                try data.write(to: coordinatedURL, options: replacing ? .atomic : .withoutOverwriting)
            } catch {
                writeError = error
            }
        }
        if let coordinationError {
            throw coordinationError
        }
        if let writeError {
            throw writeError
        }
    }

    static func location(_ url: URL) -> String {
        url.standardizedFileURL.path
    }

    static func uniqueURL(in directory: URL, fileName: String) -> URL {
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
}
