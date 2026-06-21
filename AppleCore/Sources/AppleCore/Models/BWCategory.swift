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

nonisolated public struct BWCategory: Codable, Sendable, Identifiable {
    public var id: UUID
    public var ordinal: Int
    public var title: String
    public var amountPlanned: UInt64
    public var amountActual: UInt64
    public var amountAccumulated: UInt64
    public var categoryType: BWCategoryType
    public var transactions: [BWTransaction]

    public init(
        id: UUID = UUID(),
        ordinal: Int = 0,
        title: String,
        amountPlanned: UInt64 = 0,
        amountActual: UInt64 = 0,
        amountAccumulated: UInt64 = 0,
        categoryType: BWCategoryType,
        transactions: [BWTransaction] = []
    ) {
        self.id = id
        self.ordinal = ordinal
        self.title = title
        self.amountPlanned = amountPlanned
        self.amountActual = amountActual
        self.amountAccumulated = amountAccumulated
        self.categoryType = categoryType
        self.transactions = transactions
    }
}

public extension BWCategory {
    func cloneAsTemplate() -> BWCategory {
        BWCategory(
            ordinal: ordinal,
            title: title,
            amountPlanned: amountPlanned,
            amountAccumulated: amountAccumulated,
            categoryType: categoryType
        )
    }
}
