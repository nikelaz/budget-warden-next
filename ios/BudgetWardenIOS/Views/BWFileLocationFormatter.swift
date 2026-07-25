/*
 * Budget Warden
 * Copyright (c) 2026 Lazarov & Co EOOD
 * Author: Nikola Lazarov
 *
 * Licensed under the Source-Available Educational License.
 * See the LICENSE file in the project root for full terms.
 */

import Foundation

enum BWFileLocationFormatter {
    static func displayPath(for url: URL) -> String {
        let components = url.standardizedFileURL.pathComponents

        if let mobileDocumentsIndex = components.firstIndex(of: "Mobile Documents"),
           components.indices.contains(mobileDocumentsIndex + 1) {
            let containerIndex = mobileDocumentsIndex + 1
            let containerIdentifier = components[containerIndex]
            var relativeComponents = Array(components.dropFirst(containerIndex + 1))

            if containerIdentifier == "com~apple~CloudDocs" {
                return path(["iCloud Drive"] + relativeComponents)
            }

            if relativeComponents.first == "Documents" {
                relativeComponents.removeFirst()
            }

            let containerName = (try? url.resourceValues(
                forKeys: [.ubiquitousItemContainerDisplayNameKey]
            ))?.ubiquitousItemContainerDisplayName ?? appDisplayName

            return path(["iCloud Drive", containerName] + relativeComponents)
        }

        if let documentsIndex = components.firstIndex(of: "Documents"),
           components[..<documentsIndex].contains("Application") {
            let relativeComponents = Array(components.dropFirst(documentsIndex + 1))
            return path(["On My iPhone", appDisplayName] + relativeComponents)
        }

        return url.path
    }

    private static func path(_ components: [String]) -> String {
        components.filter { !$0.isEmpty && $0 != "/" }.joined(separator: "/")
    }

    private static var appDisplayName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "Budget Warden"
    }
}
