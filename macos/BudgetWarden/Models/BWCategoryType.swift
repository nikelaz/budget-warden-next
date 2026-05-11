/* 
 * Budget Warden
 * Copyright (c) 2026 Lazarov & Co EOOD
 * Author: Nikola Lazarov
 *
 * Licensed under the Source-Available Educational License. 
 * See the LICENSE file in the project root for full terms.
 *
 */

enum BWCategoryType: Int, Codable {
    case income = 1
    case expenses = 2
    case savings = 3
    case debt = 4
}
