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

nonisolated public struct BWTransaction: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    public var title: String
    public var description: String
    public var date: Date
    public var amount: UInt64

    public init(
        id: UUID = UUID(),
        title: String,
        description: String = "",
        date: Date,
        amount: UInt64 = 0
    ) {
        self.id = id
        self.title = title
        self.description = description
        self.date = date
        self.amount = amount
    }
}
