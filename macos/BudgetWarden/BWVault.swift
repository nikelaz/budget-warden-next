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

actor BWVault: Sendable {
    var url: URL?
    

    private var fileManager: FileManager {
        FileManager.default
    }

    init() {
        // Vault folder is saved to "UserDefaults" as a "security bookmark"
        // which gives permissions to the app to access a folder, and stores
        // some details about the folder, like the URL
        guard let bookmark = UserDefaults.standard.data(forKey: "BW_VAULT_BOOKMARK") else {
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

    // Runs on the UI thread because it opens a file dialog
    @MainActor
    func selectVaultFolder() async -> Result<Void, BWError> {
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

            UserDefaults.standard.set(bookmark, forKey: "BW_VAULT_BOOKMARK")

            await setUrl(url);
            
            return .success(())
        }
        catch {
            return .failure(.vaultNotSet)
        }
    }

    // This setter is necessary as otherwise the UI thread selectVaultFolder()
    // cannot access this class to set the URL property
    private func setUrl(_ url: URL) {
        self.url = url
    }
 
    func readBudgetsFromVault() async -> Result<[BWBudget], BWError> {
        guard let url else {
            return .failure(.vaultNotSet)
        }

        return await Task.detached(priority: .userInitiated) {
            Self.readBudgetsFromDirectory(url: url)
        }.value
    }

    private static func readBudgetsFromDirectory(url: URL) -> Result<[BWBudget], BWError> {
        let didStartAccessing = url.startAccessingSecurityScopedResource()

            defer {
                if didStartAccessing {
                    url.stopAccessingSecurityScopedResource()
                }
            }

        do {
            let files = try FileManager.default.contentsOfDirectory(
                    at: url,
                    includingPropertiesForKeys: nil
                    )

                let budgetFiles = files.filter {
                    $0.pathExtension.lowercased() == "budget"
                }

            var budgets: [BWBudget] = []

                for file in budgetFiles {
                    guard let json = try? String(contentsOf: file, encoding: .utf8) else {
                        continue
                    }

                    switch BWCodec.decodeBudget(json: json, url: file) {
                        case .success(let budget):
                            budgets.append(budget)

                        case .failure:
                                continue
                    }
                }

            return .success(budgets)
        } catch {
            print(error)
                return .failure(.vaultNotSet)
        }
    }
}
