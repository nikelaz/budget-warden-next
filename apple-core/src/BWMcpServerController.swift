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
    ///   - library: The budgets the server may read and change. The app
    ///     keeps it up to date with its open and recent budgets.
    ///   - showBudget: An MCP client asked the app to open a budget.
    public init(
        keyPrefix: String,
        library: BWBudgetLibrary,
        showBudget: @escaping @MainActor @Sendable (URL) -> Void
    ) {
        self.keyPrefix = keyPrefix
        settings = BWMcpSettings.load(from: .standard, keyPrefix: keyPrefix)
        status = BWMcpServerStatus(running: false, port: 0, url: nil, localUrl: nil)
        host = BWMcpFileHost(library: library) { url in
            Task { @MainActor in showBudget(url) }
        }
        apply()
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

/// Gives the MCP server the app's budgets. Locations are standardized file
/// paths of URLs the app shared, so the server can only reach those budgets.
final class BWMcpFileHost: BWMcpHost, @unchecked Sendable {
    private let library: BWBudgetLibrary
    private let showBudget: @Sendable (URL) -> Void

    init(library: BWBudgetLibrary, showBudget: @escaping @Sendable (URL) -> Void) {
        self.library = library
        self.showBudget = showBudget
    }

    func listBudgets() -> [BWMcpBudgetLocation] {
        library.knownURLs.map { url in
            BWMcpBudgetLocation(location: BWBudgetLibrary.location(url), isOpen: library.isOpen(url))
        }
    }

    func readBudgetFile(location: String) throws -> String {
        try library.json(at: knownURL(location))
    }

    func writeBudgetFile(location: String, json: String, expectedRevisionId: String?) throws -> Bool {
        try library.write(
            json: json,
            to: knownURL(location),
            expectedRevisionID: expectedRevisionId.flatMap(UUID.init(uuidString:))
        )
    }

    func createBudgetFile(fileName: String, json: String) throws -> String {
        BWBudgetLibrary.location(try library.create(json: json, fileName: fileName))
    }

    func budgetDidChange(location: String) {
        if let url = library.knownURL(location: location) {
            library.didChange(url)
        }
    }

    func showBudget(location: String) throws {
        showBudget(try knownURL(location))
    }

    func currencyCode() -> String {
        library.defaultCurrencyCode
    }

    private func knownURL(_ location: String) throws -> URL {
        guard let url = library.knownURL(location: location) else {
            throw FfiError(message: "\(location) is not one of Budget Warden's budgets.")
        }
        return url
    }
}
