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

public enum BWError: Error, Sendable {
    case encodingJson(underlying: Error? = nil) 
    case decodingJson(underlying: Error? = nil)
    case readingFile(underlying: Error? = nil)
    case invalidBudgetFile(message: String, underlying: Error? = nil)
    case amountOverflow
    case savingFile(underlying: Error? = nil)
    case vaultNotSet(underlying: Error? = nil)
    case iCloudUnavailable(underlying: Error? = nil)
    case creatingBudget(underlying: Error? = nil)
    case saveFailed(underlying: Error? = nil)
    case saveCancelled(underlying: Error? = nil)
    case findPreviousBudget(underlying: Error? = nil)
    case budgetRemove(underlying: Error? = nil)
    case validation(underlying: Error? = nil)
    case rebaseFailed(underlying: Error? = nil)
}

extension BWError: LocalizedError {
    public var errorDescription: String? {
        switch self {
            case .encodingJson:
                return "Could not prepare your data for saving."
            case .decodingJson:
                return "Could not read the saved data."
            case .readingFile:
                return "Could not read the file."
            case .invalidBudgetFile(let message, _):
                return message
            case .amountOverflow:
                return "The budget contains an amount that is too large."
            case .savingFile:
                return "Could not save the file."
            case .vaultNotSet:
                return "No vault has been selected."
            case .iCloudUnavailable:
                return "iCloud Drive is not available. Make sure iCloud Drive is enabled."
            case .creatingBudget:
                return "Could not create the budget."
            case .saveFailed:
                return "Saving failed."
            case .saveCancelled:
                return "Saving was cancelled."
            case .findPreviousBudget:
                return "Could not find previous budget."
            case .budgetRemove:
                return "Could not remove budget."
            case .validation:
                return "The entered budget data is invalid."
            case .rebaseFailed:
                return "Could not merge your changes with the saved budget file. Try restarting the program."
        }
    }
}

extension BWError {
    public var underlyingError: Error? {
        switch self {
            case .encodingJson(let error),
                 .decodingJson(let error),
                 .readingFile(let error),
                 .invalidBudgetFile(_, let error),
                 .savingFile(let error),
                 .iCloudUnavailable(let error),
                 .creatingBudget(let error),
                 .saveFailed(let error),
                 .vaultNotSet(let error),
                 .saveCancelled(let error),
                 .findPreviousBudget(let error),
                 .budgetRemove(let error),
                 .validation(let error),
                 .rebaseFailed(let error):
                return error
            case .amountOverflow:
                return nil
        }
    }
}
