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

struct BWCategory: Codable, Sendable {
    var id: UUID = UUID()
    var ordinal: Int = 0
    var title: String
    var amountPlanned: UInt64 = 0
    var amountActual: UInt64 = 0
    var amountAccumulated: UInt64 = 0
    var categoryType: BWCategoryType
    var transactions: [BWTransaction] = []
}
