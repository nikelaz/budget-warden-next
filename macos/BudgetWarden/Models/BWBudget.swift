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

nonisolated struct BWBudget: Codable, Sendable, Identifiable {
    // Encoded
    var id: UUID = UUID()
    var title: String
    var categories: [BWCategory] = []

    // Runtime-only
    var url: URL?

    // The list below is of the keys that should be encoded/decoded
    // Basically makes "url" a runtime-only key - not JSON encoded 
    enum CodingKeys: String, CodingKey {
        case id
        case title
        case categories
    }
}
