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
    public var revisionId: UUID?
    public var schemaVersion: Int?
    public var title: String
    public var categories: [BWCategory]

    // Runtime-only
    public var url: URL?

    // The list below is of the keys that should be encoded/decoded
    // Basically makes "url" a runtime-only key - not JSON encoded 
    enum CodingKeys: String, CodingKey {
        case id
        case revision
        case revisionId
        case schemaVersion
        case title
        case categories
    }

    public init(
        id: UUID = UUID(),
        revision: Int64? = nil,
        revisionId: UUID? = nil,
        schemaVersion: Int? = nil,
        title: String,
        categories: [BWCategory] = [],
        url: URL? = nil
    ) {
        self.id = id
        self.revision = revision
        self.revisionId = revisionId
        self.schemaVersion = schemaVersion
        self.title = title
        self.categories = categories
        self.url = url
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decode(UUID.self, forKey: .id)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
        title = try container.decode(String.self, forKey: .title)
        categories = try container.decode([BWCategory].self, forKey: .categories)
        url = nil
        revision = nil
        revisionId = try container.decodeIfPresent(UUID.self, forKey: .revisionId)

        guard container.contains(.revision) else {
            return
        }

        revision = try container.decodeIfPresent(Int64.self, forKey: .revision)
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
