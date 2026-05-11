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
import AppKit

private let VAULT_BOOKMARK_KEY = "BW_VAULT_BOOKMARK"

struct BWVault: Sendable {
    var url: URL?

    private var fileManager: FileManager {
        FileManager.default
    }

    init() {
        // Vault folder is saved to "UserDefaults" as a "security bookmark"
        // which gives permissions to the app to access a folder, and stores
        // some details about the folder, like the URL
        guard let bookmark = UserDefaults.standard.data(forKey: VAULT_BOOKMARK_KEY) else {
            return
        }

        do {
            var isStale = false

            let resolvedUrl = try URL(
                resolvingBookmarkData: bookmark,
                options: .withSecurityScope,
                bookmarkDataIsStale: &isStale
            )

            self.url = resolvedUrl
        }
        catch {
            self.url = nil
        }
    }

    mutating func selectVaultFolder() -> Result<Void, BWError> {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK else {
            return .failure(.vaultNotSet)
        }

        guard let url = panel.url else {
            return .failure(.vaultNotSet)
        }

        do {
            let bookmark = try url.bookmarkData(
                options: .withSecurityScope,
            )

            UserDefaults.standard.set(bookmark, forKey: VAULT_BOOKMARK_KEY)


            self.url = url
            return .success(())
        }
        catch {
            return .failure(.vaultNotSet)
        }
    }

    func readBudgetsFromVault() -> Result<[BWBudget], BWError> {
        guard let url = url else {
            return .failure(.vaultNotSet)
        }

        // This startAccessing... call is needed in order to use the permissions
        // granted from the "security bookmark"
        let didStartAccessing = url.startAccessingSecurityScopedResource()

        defer {
            if didStartAccessing {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let budgets = readBudgetsFromDirectory(url: url)

        return .success(budgets)
    }
 
    private func readBudgetsFromDirectory(url: URL) -> [BWBudget] {
        guard let files = try? fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }

        let budgetFiles = files.filter { $0.pathExtension == "budget" }

        var budgets: [BWBudget] = []

        for file in budgetFiles {
            guard let json = try? String(contentsOf: file, encoding: .utf8) else {
                continue
            }

            let result = BWCodec.decodeBudget(json: json)

            switch result {
            case .success(let budget):
                budgets.append(budget)

            case .failure:
                continue
            }
        }

        return budgets
    }
}
