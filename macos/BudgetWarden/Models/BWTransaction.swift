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

nonisolated struct BWTransaction: Codable, Sendable {
    var id: UUID = UUID()
    var title: String
    var description: String = ""
    var date: Date 
    var amount: UInt64 = 0
}
