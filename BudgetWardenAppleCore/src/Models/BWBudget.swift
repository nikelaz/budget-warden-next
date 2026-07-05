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
    public var revision: UUID?
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
        case schemaVersion
        case title
        case categories
    }

    public init(
        id: UUID = UUID(),
        revision: UUID? = nil,
        schemaVersion: Int? = nil,
        title: String,
        categories: [BWCategory] = [],
        url: URL? = nil
    ) {
        self.id = id
        self.revision = revision
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

        guard container.contains(.revision) else {
            return
        }

        do {
            revision = try container.decodeIfPresent(UUID.self, forKey: .revision)
        }
        catch let uuidDecodingError {
            do {
                _ = try container.decode(Int64.self, forKey: .revision)
                revision = UUID()
            }
            catch {
                throw uuidDecodingError
            }
        }
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
