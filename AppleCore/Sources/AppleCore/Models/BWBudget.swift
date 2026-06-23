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
    public static let currentSchemaVersion = 2

    // Encoded
    public var id: UUID
    public var schemaVersion: Int
    public var revisionID: UUID
    public var modifiedAt: Date
    public var modifiedByDeviceID: String?
    public var title: String
    public var categories: [BWCategory]

    // Runtime-only
    public var url: URL?

    // The list below is of the keys that should be encoded/decoded
    // Basically makes "url" a runtime-only key - not JSON encoded 
    enum CodingKeys: String, CodingKey {
        case id
        case schemaVersion
        case revisionID
        case modifiedAt
        case modifiedByDeviceID
        case title
        case categories
    }

    public init(
        id: UUID = UUID(),
        schemaVersion: Int = Self.currentSchemaVersion,
        revisionID: UUID = UUID(),
        modifiedAt: Date = Date(),
        modifiedByDeviceID: String? = nil,
        title: String,
        categories: [BWCategory] = [],
        url: URL? = nil
    ) {
        self.id = id
        self.schemaVersion = schemaVersion
        self.revisionID = revisionID
        self.modifiedAt = modifiedAt
        self.modifiedByDeviceID = modifiedByDeviceID
        self.title = title
        self.categories = categories
        self.url = url
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decode(UUID.self, forKey: .id)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        revisionID = try container.decodeIfPresent(UUID.self, forKey: .revisionID) ?? id
        modifiedAt = try container.decodeIfPresent(Date.self, forKey: .modifiedAt) ?? .distantPast
        modifiedByDeviceID = try container.decodeIfPresent(String.self, forKey: .modifiedByDeviceID)
        title = try container.decode(String.self, forKey: .title)
        categories = try container.decode([BWCategory].self, forKey: .categories)
        url = nil
    }

    public func withNewRevision(modifiedByDeviceID: String) -> BWBudget {
        var budget = self
        budget.schemaVersion = Self.currentSchemaVersion
        budget.revisionID = UUID()
        budget.modifiedAt = Date()
        budget.modifiedByDeviceID = modifiedByDeviceID
        return budget
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
