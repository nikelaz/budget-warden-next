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

nonisolated public struct BWBudget: Codable, Sendable, Identifiable {
    // Encoded
    public var id: UUID
    public var revision: Int64?
    public var schemaVersion: Int?
    public var title: String
    public var categories: [BWCategory]
    public var crdt: BWCRDTState?

    // Runtime-only
    public var url: URL?
    public var requiresCRDTWriteback: Bool = false

    // The list below is of the keys that should be encoded/decoded
    // Basically makes "url" a runtime-only key - not JSON encoded 
    enum CodingKeys: String, CodingKey {
        case id
        case revision
        case schemaVersion
        case title
        case categories
        case crdt
    }

    public init(
        id: UUID = UUID(),
        title: String,
        categories: [BWCategory] = [],
        url: URL? = nil
    ) {
        self.id = id
        self.title = title
        self.categories = categories
        self.crdt = nil
        self.url = url
    }
}

public extension BWBudget {
    func cloneAsTemplate(newTitle: String) -> BWBudget {
        BWBudget(
            title: newTitle,
            categories: categories.map { $0.cloneAsTemplate() },
            url: nil
        )
    }
}
