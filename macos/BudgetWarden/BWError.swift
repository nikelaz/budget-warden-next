/* 
 * Budget Warden
 * Copyright (c) 2026 Lazarov & Co EOOD
 * Author: Nikola Lazarov
 *
 * Licensed under the Source-Available Educational License. 
 * See the LICENSE file in the project root for full terms.
 *
 */

enum BWError: Error {
    case encodingJson 
    case decodingJson
    case savingFile
    case vaultNotSet
}
