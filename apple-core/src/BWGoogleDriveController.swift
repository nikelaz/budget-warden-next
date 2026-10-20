/*
 * Budget Warden
 * Copyright (c) 2026 Lazarov & Co EOOD
 * Author: Nikola Lazarov
 *
 * Licensed under the Source-Available Educational License.
 * See the LICENSE file in the project root for full terms.
 */

import AuthenticationServices
import BWCore
import Foundation
import Observation
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// The core Google Drive engine. Its methods block on the network, so they
/// only run off the main actor.
private final class BWGoogleDriveEngine: @unchecked Sendable {
    let drive: BWGoogleDrive

    init(drive: BWGoogleDrive) {
        self.drive = drive
    }

    func run<T: Sendable>(_ work: @escaping @Sendable (BWGoogleDrive) throws -> T) async throws -> T {
        let drive = drive
        do {
            return try await Task.detached(priority: .userInitiated) { try work(drive) }.value
        } catch {
            throw BWCloudError(error)
        }
    }
}

/// Google Drive budgets for the Apple apps: sign-in, listing (including
/// budgets others shared with the user), opening, sync, and sharing.
///
/// A cloud budget opens from a working copy in `cacheDirectory`. The app
/// saves to that file as usual and calls ``sync(budgetAt:)`` afterwards.
@MainActor
@Observable
public final class BWGoogleDriveController {
    public private(set) var isConfigured: Bool
    public private(set) var isSignedIn: Bool
    public private(set) var accountEmail: String?
    public private(set) var budgets: [BWCloudBudget]
    public private(set) var isRefreshing = false
    public private(set) var isSigningIn = false
    /// The latest listing or sync problem, for display next to the list.
    public private(set) var lastError: String?

    @ObservationIgnored private let engine: BWGoogleDriveEngine
    @ObservationIgnored private let clientID: String
    @ObservationIgnored private let budgetDidChange: @MainActor (URL) -> Void
    @ObservationIgnored private var syncing: Set<String> = []
    @ObservationIgnored private var syncAgain: Set<String> = []
    @ObservationIgnored private var authenticationSession: ASWebAuthenticationSession?
    @ObservationIgnored private let presentationContext = BWWebAuthenticationContext()

    /// - Parameters:
    ///   - clientID: OAuth client ID of an iOS-type Google client. The
    ///     `BWGoogleClientID` Info.plist key supplies it by default.
    ///   - keychainService: Keychain service that holds the sign-in.
    ///   - budgetDidChange: Sync rewrote the working copy at a URL.
    public init(
        clientID: String? = Bundle.main.object(forInfoDictionaryKey: "BWGoogleClientID") as? String,
        cacheDirectory: URL = BWGoogleDriveController.defaultCacheDirectory(),
        keychainService: String = "com.lazarovco.budgetwarden.google-drive",
        budgetDidChange: @escaping @MainActor (URL) -> Void
    ) {
        let trimmed = clientID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // An unexpanded build setting means the build has no client ID.
        let resolvedClientID = trimmed.hasPrefix("$(") ? "" : trimmed
        self.clientID = resolvedClientID
        let drive = BWGoogleDrive(config: BWGoogleDriveConfig(
            clientId: resolvedClientID,
            clientSecret: nil,
            cacheDirectory: cacheDirectory.path,
            folderName: "Budget Warden"
        ))
        drive.connect(
            http: BWURLSessionHTTPClient(),
            credentials: BWKeychainCredentialStore(service: keychainService)
        )
        engine = BWGoogleDriveEngine(drive: drive)
        self.budgetDidChange = budgetDidChange
        isConfigured = drive.isConfigured()
        isSignedIn = drive.isSignedIn()
        accountEmail = drive.account()?.email
        budgets = drive.cachedBudgets()
    }

    public nonisolated static func defaultCacheDirectory() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support.appendingPathComponent("Cloud Budgets", isDirectory: true)
    }

    // MARK: Account

    /// Signs in with Google in a system authentication session.
    public func signIn() async {
        guard isConfigured, !isSigningIn else { return }
        isSigningIn = true
        lastError = nil
        defer {
            isSigningIn = false
            authenticationSession = nil
        }
        do {
            let clientID = clientID
            let request = try await engine.run { drive in
                try drive.beginSignIn(redirectUri: googleAppleRedirectUri(clientId: clientID))
            }
            guard let url = URL(string: request.authorizationUrl) else { return }
            let callback = try await authenticate(at: url)
            let account = try await engine.run { drive in
                try drive.completeSignIn(callbackUrl: callback.absoluteString)
            }
            accountEmail = account.email
            refreshAccountState()
            await refresh()
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            // The user closed the sign-in sheet.
        } catch {
            lastError = BWCloudError(error).message
        }
    }

    private func authenticate(at url: URL) async throws -> URL {
        let scheme = googleAppleCallbackScheme(clientId: clientID)
        return try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: scheme) { callback, error in
                if let callback {
                    continuation.resume(returning: callback)
                } else {
                    continuation.resume(throwing: error ?? BWCloudError(message: "Google sign-in did not finish."))
                }
            }
            session.presentationContextProvider = presentationContext
            session.prefersEphemeralWebBrowserSession = false
            authenticationSession = session
            if !session.start() {
                authenticationSession = nil
                continuation.resume(throwing: BWCloudError(message: "Could not open Google sign-in."))
            }
        }
    }

    /// Signs out and removes working copies from this device.
    public func signOut() async {
        _ = try? await engine.run { drive in drive.signOut() }
        budgets = []
        lastError = nil
        refreshAccountState()
    }

    private func refreshAccountState() {
        isSignedIn = engine.drive.isSignedIn()
        accountEmail = engine.drive.account()?.email
    }

    // MARK: Budgets

    /// Lists budgets in Google Drive, including ones shared with the user.
    public func refresh() async {
        guard isSignedIn, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            budgets = try await engine.run { drive in try drive.listBudgets() }
            lastError = nil
        } catch {
            let error = BWCloudError(error)
            lastError = error.message
            if error.requiresSignIn {
                refreshAccountState()
            }
        }
    }

    public func budget(withID id: String) -> BWCloudBudget? {
        budgets.first { $0.id == id }
    }

    /// Downloads a budget if needed and returns its working copy.
    public func open(_ budget: BWCloudBudget) async throws -> URL {
        let result = try await engine.run { drive in try drive.openBudget(fileId: budget.id) }
        remember(result.budget)
        return URL(fileURLWithPath: result.localPath)
    }

    /// Uploads an encoded budget as a new cloud budget and returns its
    /// working copy.
    public func createBudget(fileName: String, json: String) async throws -> URL {
        let budget = try await engine.run { drive in try drive.createBudget(fileName: fileName, json: json) }
        remember(budget)
        guard let path = budget.localPath else {
            throw BWCloudError(message: "The new budget has no local copy.")
        }
        return URL(fileURLWithPath: path)
    }

    /// The Drive file ID of a working copy, or `nil` for other files.
    public func budgetID(for url: URL) -> String? {
        engine.drive.budgetIdForPath(path: url.standardizedFileURL.path)
    }

    public func isCloudURL(_ url: URL) -> Bool {
        engine.drive.isCloudPath(path: url.standardizedFileURL.path)
    }

    /// Reconciles a working copy with Drive. Requests made while that budget
    /// is syncing run once more afterwards, so the latest save is uploaded.
    public func sync(budgetAt url: URL) {
        guard let id = budgetID(for: url) else { return }
        sync(id: id)
    }

    public func sync(id: String) {
        guard !syncing.contains(id) else {
            syncAgain.insert(id)
            return
        }
        syncing.insert(id)
        Task {
            repeat {
                syncAgain.remove(id)
                do {
                    let result = try await engine.run { drive in try drive.syncBudget(fileId: id) }
                    remember(result.budget)
                    lastError = nil
                    if result.localChanged {
                        budgetDidChange(URL(fileURLWithPath: result.localPath))
                    }
                } catch {
                    // Sync runs again after the next save or timer tick.
                    let error = BWCloudError(error)
                    lastError = error.message
                    if error.requiresSignIn {
                        refreshAccountState()
                    }
                }
            } while syncAgain.contains(id)
            syncing.remove(id)
        }
    }

    private func remember(_ budget: BWCloudBudget) {
        if let index = budgets.firstIndex(where: { $0.id == budget.id }) {
            budgets[index] = budget
        } else {
            budgets.insert(budget, at: 0)
        }
    }

    // MARK: Sharing

    /// Invites `email` to a budget. Google emails them a link, and their
    /// Budget Warden lists the budget under budgets shared with them.
    public func share(
        _ budget: BWCloudBudget,
        with email: String,
        canEdit: Bool,
        message: String?
    ) async throws {
        let role: BWCloudShareRole = canEdit ? .writer : .reader
        _ = try await engine.run { drive in
            try drive.shareBudget(fileId: budget.id, email: email, role: role, message: message)
        }
        if let index = budgets.firstIndex(where: { $0.id == budget.id }) {
            budgets[index].isShared = true
        }
    }

    public func shares(of budget: BWCloudBudget) async throws -> [BWCloudShare] {
        try await engine.run { drive in try drive.listShares(fileId: budget.id) }
    }

    public func removeShare(_ share: BWCloudShare, from budget: BWCloudBudget) async throws {
        try await engine.run { drive in try drive.removeShare(fileId: budget.id, shareId: share.id) }
    }
}

public extension BWCloudBudget {
    /// "Shared by Ana", "Google Drive · Shared", or "Google Drive".
    var locationDescription: String {
        let who = ownerName ?? ownerEmail ?? "someone"
        switch (sharedWithMe, canEdit, isShared) {
        case (true, true, _): return "Shared by \(who)"
        case (true, false, _): return "Shared by \(who) · View only"
        case (false, _, true): return "Google Drive · Shared"
        case (false, _, false): return "Google Drive"
        }
    }
}

/// Anchors the Google sign-in sheet to the app's key window.
final class BWWebAuthenticationContext: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            #if canImport(AppKit)
            return NSApp.keyWindow ?? NSApp.windows.first ?? ASPresentationAnchor()
            #else
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            return scenes.flatMap(\.windows).first(where: \.isKeyWindow)
                ?? scenes.first.map { ASPresentationAnchor(windowScene: $0) }
                ?? ASPresentationAnchor()
            #endif
        }
    }
}
