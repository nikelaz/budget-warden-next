/*
 * Budget Warden
 * Copyright (c) 2026 Lazarov & Co EOOD
 * Author: Nikola Lazarov
 *
 * Licensed under the Source-Available Educational License.
 * See the LICENSE file in the project root for full terms.
 */

import BudgetWardenAppleCore
import GoogleSignIn
import Observation
import UIKit

private struct BWGoogleDriveConfigurationError: LocalizedError {
    var errorDescription: String? {
        "Set GOOGLE_CLIENT_ID and GOOGLE_REVERSED_CLIENT_ID in the Apple app target’s build settings before connecting Google Drive."
    }
}

@MainActor
@Observable
final class BWGoogleDriveSession {
    private(set) var accountEmail: String?
    private(set) var isRestoring = false
    private(set) var isConnecting = false

    var isConnected: Bool {
        GIDSignIn.sharedInstance.currentUser?.grantedScopes?
            .contains(BWGoogleDriveRepository.driveScope) == true
    }

    func restore() async {
        guard !isRestoring else { return }
        guard (try? configure()) != nil else { return }
        isRestoring = true
        defer { isRestoring = false }

        do {
            let user = try await GIDSignIn.sharedInstance.restorePreviousSignIn()
            accountEmail = user.profile?.email
        }
        catch {
            accountEmail = nil
        }
    }

    func connect() async throws {
        guard !isConnecting else { return }
        try configure()
        guard let presenter = Self.presentingViewController else {
            throw BWError.googleDrive()
        }

        isConnecting = true
        defer { isConnecting = false }

        let result: GIDSignInResult
        if let user = GIDSignIn.sharedInstance.currentUser {
            result = try await user.addScopes(
                [BWGoogleDriveRepository.driveScope],
                presenting: presenter
            )
        }
        else {
            result = try await GIDSignIn.sharedInstance.signIn(
                withPresenting: presenter,
                hint: accountEmail,
                additionalScopes: [BWGoogleDriveRepository.driveScope]
            )
        }
        accountEmail = result.user.profile?.email
    }

    func accessToken() async throws -> String {
        guard let user = GIDSignIn.sharedInstance.currentUser else {
            throw BWError.googleDrive()
        }
        guard user.grantedScopes?.contains(BWGoogleDriveRepository.driveScope) == true else {
            throw BWError.googleDrive()
        }
        let refreshed = try await user.refreshTokensIfNeeded()
        accountEmail = refreshed.profile?.email
        return refreshed.accessToken.tokenString
    }

    func disconnect() {
        GIDSignIn.sharedInstance.signOut()
        accountEmail = nil
    }

    private func configure() throws {
        guard let clientID = Bundle.main.object(forInfoDictionaryKey: "GIDClientID") as? String,
              !clientID.isEmpty,
              !clientID.contains("$(") else {
            throw BWGoogleDriveConfigurationError()
        }
        GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)
    }

    private static var presentingViewController: UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        var presenter = scene?.keyWindow?.rootViewController
        while let presented = presenter?.presentedViewController {
            presenter = presented
        }
        return presenter
    }
}
