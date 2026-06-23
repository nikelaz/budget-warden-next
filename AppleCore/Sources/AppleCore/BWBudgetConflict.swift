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

public enum BWBudgetConflictChoice: Sendable {
    case local
    case latest
}

public enum BWBudgetConflictKey: Equatable, Sendable {
    case budget
    case category(UUID)
    case transaction(UUID)
}

public struct BWTransactionConflictValue: Sendable {
    public var categoryID: UUID
    public var categoryTitle: String
    public var transaction: BWTransaction

    public init(
        categoryID: UUID,
        categoryTitle: String,
        transaction: BWTransaction
    ) {
        self.categoryID = categoryID
        self.categoryTitle = categoryTitle
        self.transaction = transaction
    }
}

public enum BWBudgetConflictItem: Sendable {
    case budget(localTitle: String, latestTitle: String)
    case category(local: BWCategory?, latest: BWCategory?)
    case transaction(local: BWTransactionConflictValue?, latest: BWTransactionConflictValue?)

    public var key: BWBudgetConflictKey {
        switch self {
            case .budget:
                return .budget
            case .category(let local, let latest):
                return .category((local ?? latest)?.id ?? UUID())
            case .transaction(let local, let latest):
                return .transaction((local ?? latest)?.transaction.id ?? UUID())
        }
    }

    public var title: String {
        switch self {
            case .budget:
                return "Budget Changed"
            case .category:
                return "Category Changed"
            case .transaction:
                return "Transaction Changed"
        }
    }
}

public struct BWBudgetMergeResolution: Sendable {
    public var key: BWBudgetConflictKey
    public var choice: BWBudgetConflictChoice

    public init(key: BWBudgetConflictKey, choice: BWBudgetConflictChoice) {
        self.key = key
        self.choice = choice
    }
}

public struct BWBudgetSaveConflict: Identifiable, Sendable {
    public var id: UUID
    public var fileURL: URL
    public var baseBudget: BWBudget
    public var localBudget: BWBudget
    public var latestBudget: BWBudget
    public var item: BWBudgetConflictItem

    public init(
        id: UUID = UUID(),
        fileURL: URL,
        baseBudget: BWBudget,
        localBudget: BWBudget,
        latestBudget: BWBudget,
        item: BWBudgetConflictItem
    ) {
        self.id = id
        self.fileURL = fileURL
        self.baseBudget = baseBudget
        self.localBudget = localBudget
        self.latestBudget = latestBudget
        self.item = item
    }
}

public enum BWBudgetSaveOutcome: Sendable {
    case saved(BWBudget)
    case conflict(BWBudgetSaveConflict)
}

