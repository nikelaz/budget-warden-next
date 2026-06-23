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

public enum BWBudgetMergeResult: Sendable {
    case merged(BWBudget)
    case conflict(BWBudgetConflictItem)
}

public enum BWBudgetMerge {
    public static func merge(
        base: BWBudget,
        local: BWBudget,
        latest: BWBudget,
        resolution: BWBudgetMergeResolution? = nil
    ) -> BWBudgetMergeResult {
        var merged = latest
        merged.url = latest.url ?? local.url ?? base.url

        switch mergeBudgetTitle(base: base, local: local, latest: latest, resolution: resolution) {
            case .merged(let title):
                merged.title = title
            case .conflict(let item):
                return .conflict(item)
        }

        switch mergeCategoryShells(base: base, local: local, latest: latest, resolution: resolution) {
            case .merged(let categories):
                merged.categories = categories
            case .conflict(let item):
                return .conflict(item)
        }

        switch mergeTransactions(base: base, local: local, latest: latest, into: &merged, resolution: resolution) {
            case .merged:
                break
            case .conflict(let item):
                return .conflict(item)
        }

        guard BWCodec.normalizeActualAmounts(in: &merged) else {
            return .conflict(.budget(localTitle: local.title, latestTitle: latest.title))
        }

        for categoryType in BWCategoryType.allCases {
            BWBudgetMutation.normalizeCategoryOrdinals(in: &merged, for: categoryType)
        }

        return .merged(merged)
    }

    private static func mergeBudgetTitle(
        base: BWBudget,
        local: BWBudget,
        latest: BWBudget,
        resolution: BWBudgetMergeResolution?
    ) -> ScalarMergeResult<String> {
        let localChanged = local.title != base.title
        let latestChanged = latest.title != base.title

        guard localChanged && latestChanged && local.title != latest.title else {
            return .merged(localChanged ? local.title : latest.title)
        }

        let item = BWBudgetConflictItem.budget(
            localTitle: local.title,
            latestTitle: latest.title
        )

        if let choice = resolve(item, resolution: resolution) {
            return .merged(choice == .local ? local.title : latest.title)
        }

        return .conflict(item)
    }

    private static func mergeCategoryShells(
        base: BWBudget,
        local: BWBudget,
        latest: BWBudget,
        resolution: BWBudgetMergeResolution?
    ) -> ScalarMergeResult<[BWCategory]> {
        let baseCategories = categoryMap(in: base)
        let localCategories = categoryMap(in: local)
        let latestCategories = categoryMap(in: latest)
        var mergedByID: [UUID: BWCategory] = [:]

        for categoryID in orderedCategoryIDs(base: base, local: local, latest: latest) {
            let baseCategory = baseCategories[categoryID]
            let localCategory = localCategories[categoryID]
            let latestCategory = latestCategories[categoryID]

            switch mergeCategoryShell(
                base: baseCategory,
                local: localCategory,
                latest: latestCategory,
                resolution: resolution
            ) {
                case .merged(let category):
                    if var category {
                        category.transactions = []
                        mergedByID[category.id] = category
                    }
                case .conflict(let item):
                    return .conflict(item)
            }
        }

        let categories = orderedCategoryIDs(base: base, local: local, latest: latest)
            .compactMap { mergedByID[$0] }

        return .merged(categories)
    }

    private static func mergeCategoryShell(
        base: BWCategory?,
        local: BWCategory?,
        latest: BWCategory?,
        resolution: BWBudgetMergeResolution?
    ) -> ScalarMergeResult<BWCategory?> {
        let key = BWBudgetConflictKey.category((local ?? latest ?? base)?.id ?? UUID())

        switch (base, local, latest) {
            case (nil, nil, nil):
                return .merged(nil)
            case (nil, let local?, nil):
                return .merged(local)
            case (nil, nil, let latest?):
                return .merged(latest)
            case (nil, let local?, let latest?):
                guard categoryScalarsEqual(local, latest) else {
                    return resolveCategoryConflict(local: local, latest: latest, key: key, resolution: resolution)
                }

                return .merged(latest)
            case (let base?, nil, nil):
                _ = base
                return .merged(nil)
            case (let base?, nil, let latest?):
                guard categoryContentEqual(base, latest) else {
                    return resolveCategoryConflict(local: nil, latest: latest, key: key, resolution: resolution)
                }

                return .merged(nil)
            case (let base?, let local?, nil):
                guard categoryContentEqual(base, local) else {
                    return resolveCategoryConflict(local: local, latest: nil, key: key, resolution: resolution)
                }

                return .merged(nil)
            case (let base?, let local?, let latest?):
                let localChanged = !categoryScalarsEqual(base, local)
                let latestChanged = !categoryScalarsEqual(base, latest)

                if localChanged && latestChanged && !categoryScalarsEqual(local, latest) {
                    return resolveCategoryConflict(local: local, latest: latest, key: key, resolution: resolution)
                }

                return .merged(localChanged ? local : latest)
        }
    }

    private static func mergeTransactions(
        base: BWBudget,
        local: BWBudget,
        latest: BWBudget,
        into merged: inout BWBudget,
        resolution: BWBudgetMergeResolution?
    ) -> MergeStepResult {
        let baseTransactions = transactionMap(in: base)
        let localTransactions = transactionMap(in: local)
        let latestTransactions = transactionMap(in: latest)
        var mergedEntries: [TransactionEntry] = []

        for transactionID in orderedTransactionIDs(base: base, local: local, latest: latest) {
            let baseEntry = baseTransactions[transactionID]
            let localEntry = localTransactions[transactionID]
            let latestEntry = latestTransactions[transactionID]

            switch mergeTransaction(
                base: baseEntry,
                local: localEntry,
                latest: latestEntry,
                localBudget: local,
                latestBudget: latest,
                resolution: resolution
            ) {
                case .merged(let entry):
                    if let entry {
                        mergedEntries.append(entry)
                    }
                case .conflict(let item):
                    return .conflict(item)
            }
        }

        for index in merged.categories.indices {
            merged.categories[index].transactions = []
        }

        for entry in mergedEntries {
            guard let categoryIndex = merged.categories.firstIndex(where: { $0.id == entry.categoryID }) else {
                continue
            }

            merged.categories[categoryIndex].transactions.append(entry.transaction)
        }

        return .merged
    }

    private static func mergeTransaction(
        base: TransactionEntry?,
        local: TransactionEntry?,
        latest: TransactionEntry?,
        localBudget: BWBudget,
        latestBudget: BWBudget,
        resolution: BWBudgetMergeResolution?
    ) -> ScalarMergeResult<TransactionEntry?> {
        let key = BWBudgetConflictKey.transaction((local ?? latest ?? base)?.transaction.id ?? UUID())

        switch (base, local, latest) {
            case (nil, nil, nil):
                return .merged(nil)
            case (nil, let local?, nil):
                return .merged(local)
            case (nil, nil, let latest?):
                return .merged(latest)
            case (nil, let local?, let latest?):
                guard transactionEntriesEqual(local, latest) else {
                    return resolveTransactionConflict(
                        local: local,
                        latest: latest,
                        localBudget: localBudget,
                        latestBudget: latestBudget,
                        key: key,
                        resolution: resolution
                    )
                }

                return .merged(latest)
            case (let base?, nil, nil):
                _ = base
                return .merged(nil)
            case (let base?, nil, let latest?):
                guard transactionEntriesEqual(base, latest) else {
                    return resolveTransactionConflict(
                        local: nil,
                        latest: latest,
                        localBudget: localBudget,
                        latestBudget: latestBudget,
                        key: key,
                        resolution: resolution
                    )
                }

                return .merged(nil)
            case (let base?, let local?, nil):
                guard transactionEntriesEqual(base, local) else {
                    return resolveTransactionConflict(
                        local: local,
                        latest: nil,
                        localBudget: localBudget,
                        latestBudget: latestBudget,
                        key: key,
                        resolution: resolution
                    )
                }

                return .merged(nil)
            case (let base?, let local?, let latest?):
                let localChanged = !transactionEntriesEqual(base, local)
                let latestChanged = !transactionEntriesEqual(base, latest)

                if localChanged && latestChanged && !transactionEntriesEqual(local, latest) {
                    return resolveTransactionConflict(
                        local: local,
                        latest: latest,
                        localBudget: localBudget,
                        latestBudget: latestBudget,
                        key: key,
                        resolution: resolution
                    )
                }

                return .merged(localChanged ? local : latest)
        }
    }

    private static func resolveCategoryConflict(
        local: BWCategory?,
        latest: BWCategory?,
        key: BWBudgetConflictKey,
        resolution: BWBudgetMergeResolution?
    ) -> ScalarMergeResult<BWCategory?> {
        let item = BWBudgetConflictItem.category(local: local, latest: latest)

        if let choice = resolve(item, resolution: resolution, expectedKey: key) {
            return .merged(choice == .local ? local : latest)
        }

        return .conflict(item)
    }

    private static func resolveTransactionConflict(
        local: TransactionEntry?,
        latest: TransactionEntry?,
        localBudget: BWBudget,
        latestBudget: BWBudget,
        key: BWBudgetConflictKey,
        resolution: BWBudgetMergeResolution?
    ) -> ScalarMergeResult<TransactionEntry?> {
        let item = BWBudgetConflictItem.transaction(
            local: local.map { conflictValue(for: $0, in: localBudget) },
            latest: latest.map { conflictValue(for: $0, in: latestBudget) }
        )

        if let choice = resolve(item, resolution: resolution, expectedKey: key) {
            return .merged(choice == .local ? local : latest)
        }

        return .conflict(item)
    }

    private static func resolve(
        _ item: BWBudgetConflictItem,
        resolution: BWBudgetMergeResolution?,
        expectedKey: BWBudgetConflictKey? = nil
    ) -> BWBudgetConflictChoice? {
        guard let resolution else {
            return nil
        }

        let key = expectedKey ?? item.key
        guard resolution.key == key else {
            return nil
        }

        return resolution.choice
    }

    private static func categoryMap(in budget: BWBudget) -> [UUID: BWCategory] {
        Dictionary(uniqueKeysWithValues: budget.categories.map { ($0.id, $0) })
    }

    private static func orderedCategoryIDs(base: BWBudget, local: BWBudget, latest: BWBudget) -> [UUID] {
        orderedIDs(
            latest.categories.map(\.id),
            local.categories.map(\.id),
            base.categories.map(\.id)
        )
    }

    private static func orderedTransactionIDs(base: BWBudget, local: BWBudget, latest: BWBudget) -> [UUID] {
        orderedIDs(
            transactionOrder(in: latest),
            transactionOrder(in: local),
            transactionOrder(in: base)
        )
    }

    private static func orderedIDs(_ groups: [UUID]...) -> [UUID] {
        var seen = Set<UUID>()
        var ordered: [UUID] = []

        for group in groups {
            for id in group where !seen.contains(id) {
                seen.insert(id)
                ordered.append(id)
            }
        }

        return ordered
    }

    private static func transactionOrder(in budget: BWBudget) -> [UUID] {
        budget.categories.flatMap { category in
            category.transactions.map(\.id)
        }
    }

    private static func transactionMap(in budget: BWBudget) -> [UUID: TransactionEntry] {
        var entries: [UUID: TransactionEntry] = [:]

        for category in budget.categories {
            for transaction in category.transactions {
                entries[transaction.id] = TransactionEntry(
                    categoryID: category.id,
                    transaction: transaction
                )
            }
        }

        return entries
    }

    private static func conflictValue(
        for entry: TransactionEntry,
        in budget: BWBudget
    ) -> BWTransactionConflictValue {
        let categoryTitle = budget.categories.first(where: { $0.id == entry.categoryID })?.title ?? "Deleted Category"

        return BWTransactionConflictValue(
            categoryID: entry.categoryID,
            categoryTitle: categoryTitle,
            transaction: entry.transaction
        )
    }

    private static func categoryScalarsEqual(_ lhs: BWCategory, _ rhs: BWCategory) -> Bool {
        lhs.id == rhs.id
            && lhs.ordinal == rhs.ordinal
            && lhs.title == rhs.title
            && lhs.amountPlanned == rhs.amountPlanned
            && lhs.amountAccumulated == rhs.amountAccumulated
            && lhs.categoryType == rhs.categoryType
    }

    private static func categoryContentEqual(_ lhs: BWCategory, _ rhs: BWCategory) -> Bool {
        categoryScalarsEqual(lhs, rhs)
            && lhs.transactions == rhs.transactions
    }

    private static func transactionEntriesEqual(_ lhs: TransactionEntry, _ rhs: TransactionEntry) -> Bool {
        lhs.categoryID == rhs.categoryID
            && lhs.transaction == rhs.transaction
    }
}

private struct TransactionEntry: Sendable {
    var categoryID: UUID
    var transaction: BWTransaction
}

private enum ScalarMergeResult<Value>: Sendable where Value: Sendable {
    case merged(Value)
    case conflict(BWBudgetConflictItem)

    func map<NewValue: Sendable>(_ transform: (Value) -> NewValue) -> ScalarMergeResult<NewValue> {
        switch self {
            case .merged(let value):
                return .merged(transform(value))
            case .conflict(let item):
                return .conflict(item)
        }
    }
}

private enum MergeStepResult: Sendable {
    case merged
    case conflict(BWBudgetConflictItem)
}
