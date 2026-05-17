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

struct BudgetDraft {
    let title: Swift.String
    let templateURL: URL?
}

struct CategoryUpdate {
    let categoryID: Int
    let title: Swift.String
    let amountPlanned: UInt64
    let amountAccumulated: UInt64
}

struct TransactionDraft {
    let categoryID: Int
    let title: Swift.String
    let description: Swift.String
    let date: BWDate
    let amount: UInt64
}

struct TransactionUpdate {
    let transactionID: Int
    let categoryID: Int
    let title: Swift.String
    let description: Swift.String
    let date: BWDate
    let amount: UInt64
}
