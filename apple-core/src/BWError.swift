/*
 * Budget Warden
 * Copyright (c) 2026 Lazarov & Co EOOD
 * Author: Nikola Lazarov
 *
 * Licensed under the Source-Available Educational License.
 * See the LICENSE file in the project root for full terms.
 */

import Foundation

public enum BWError: Error, Sendable {
    case readingFile(Error? = nil)
    case decodingFile(Error? = nil)
    case savingFile(Error? = nil)
    case creatingBudget(Error? = nil)
    case deletingBudget(Error? = nil)
    case removingRecentItem(Error? = nil)
    case core(String)
    case validation(String)

    public var underlyingError: Error? {
        switch self {
        case .readingFile(let error),
             .decodingFile(let error),
             .savingFile(let error),
             .creatingBudget(let error),
             .deletingBudget(let error),
             .removingRecentItem(let error):
            return error
        case .core, .validation:
            return nil
        }
    }
}

extension BWError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .readingFile:
            return "Could not read the budget file."
        case .decodingFile:
            return "The budget file is corrupted and cannot be opened."
        case .savingFile:
            return "Could not save the budget file."
        case .creatingBudget:
            return "Could not create the budget."
        case .deletingBudget:
            return "Could not delete the budget file."
        case .removingRecentItem:
            return "Could not remove the item from Recents."
        case .core(let message), .validation(let message):
            return message
        }
    }
}
