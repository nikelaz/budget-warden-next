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

enum BWError: Error, Sendable {
    case encodingJson(underlying: Error? = nil) 
    case decodingJson(underlying: Error? = nil)
    case savingFile(underlying: Error? = nil)
    case vaultNotSet(underlying: Error? = nil)
    case creatingBudget(underlying: Error? = nil)
    case saveFailed(underlying: Error? = nil)
    case saveCancelled(underlying: Error? = nil)
    case findPreviousBudget(underlying: Error? = nil)
}

extension BWError: LocalizedError {
    var errorDescription: String? {
        switch self {
            case .encodingJson:
                return "Could not prepare your data for saving."
            case .decodingJson:
                return "Could not read the saved data."
            case .savingFile:
                return "Could not save the file."
            case .vaultNotSet:
                return "No vault has been selected."
            case .creatingBudget:
                return "Could not create the budget."
            case .saveFailed:
                return "Saving failed."
            case .saveCancelled:
                return "Saving was cancelled."
            case .findPreviousBudget:
                return "Could not find previous budget."
        }
    }
}

extension BWError {
    var underlyingError: Error? {
        switch self {
            case .encodingJson(let error),
                 .decodingJson(let error),
                 .savingFile(let error),
                 .creatingBudget(let error),
                 .saveFailed(let error),
                 .vaultNotSet(let error),
                 .saveCancelled(let error),
                 .findPreviousBudget(let error):
                return error
        }
    }
}
