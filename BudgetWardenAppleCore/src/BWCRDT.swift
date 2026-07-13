/*
 * Budget Warden
 * Copyright (c) 2026 Lazarov & Co EOOD
 * Author: Nikola Lazarov
 *
 * Licensed under the Source-Available Educational License.
 * See the LICENSE file in the project root for full terms.
 */

import Foundation

public struct BWCRDTStamp: Codable, Sendable, Equatable {
    public var replicaID: String
    public var sequence: Int64
    public var context: [String: Int64]
    public var physicalMilliseconds: Int64
    public var logical: Int64

    fileprivate var totalOrder: (Int64, Int64, String, Int64) {
        (physicalMilliseconds, logical, replicaID, sequence)
    }

    fileprivate func observes(_ other: BWCRDTStamp) -> Bool {
        (replicaID == other.replicaID && sequence == other.sequence)
            || (context[other.replicaID] ?? 0) >= other.sequence
    }
}

public struct BWCRDTRegister<Value: Codable & Sendable & Equatable>: Codable, Sendable, Equatable {
    public var value: Value
    public var stamp: BWCRDTStamp

    fileprivate func merged(with other: Self) -> Self {
        if stamp == other.stamp {
            return self
        }
        if stamp.observes(other.stamp) {
            return self
        }
        if other.stamp.observes(stamp) {
            return other
        }
        return stamp.totalOrder >= other.stamp.totalOrder ? self : other
    }

    fileprivate func mergedPresence(with other: Self) -> Self where Value == Bool {
        if stamp == other.stamp {
            return self
        }
        if stamp.observes(other.stamp) {
            return self
        }
        if other.stamp.observes(stamp) {
            return other
        }
        if value != other.value {
            return value ? other : self
        }
        return stamp.totalOrder >= other.stamp.totalOrder ? self : other
    }
}

public struct BWCRDTLegacyBaseline: Codable, Sendable, Equatable, Comparable {
    public var revision: Int64
    public var fingerprint: String

    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.revision != rhs.revision {
            return lhs.revision < rhs.revision
        }
        return lhs.fingerprint < rhs.fingerprint
    }
}

public struct BWCRDTCategoryState: Codable, Sendable, Equatable {
    public var presence: BWCRDTRegister<Bool>
    public var ordinal: BWCRDTRegister<Int>
    public var title: BWCRDTRegister<String>
    public var amountPlanned: BWCRDTRegister<UInt64>
    public var amountAccumulated: BWCRDTRegister<UInt64>
    public var categoryType: BWCRDTRegister<BWCategoryType>
}

public struct BWCRDTTransactionState: Codable, Sendable, Equatable {
    public var presence: BWCRDTRegister<Bool>
    public var parentCategoryID: BWCRDTRegister<UUID>
    public var title: BWCRDTRegister<String>
    public var description: BWCRDTRegister<String>
    public var date: BWCRDTRegister<Date>
    public var amount: BWCRDTRegister<UInt64>
}

public struct BWCRDTState: Codable, Sendable, Equatable {
    public var versionVector: [String: Int64]
    public var maximumStamp: BWCRDTStamp
    public var legacyBaseline: BWCRDTLegacyBaseline?
    public var title: BWCRDTRegister<String>
    public var categories: [String: BWCRDTCategoryState]
    public var transactions: [String: BWCRDTTransactionState]

    fileprivate var containsOnlyLegacyEvents: Bool {
        !versionVector.isEmpty && versionVector.keys.allSatisfy { $0.hasPrefix("legacy:") }
    }
}

public actor BWCRDTReplicaClock {
    public static let shared = BWCRDTReplicaClock()

    private let defaults = UserDefaults.standard
    private let replicaIDKey = "BW_CRDT_REPLICA_ID_V2"
    private let sequenceKey = "BW_CRDT_REPLICA_SEQUENCE_V2"
    private let physicalKey = "BW_CRDT_HLC_PHYSICAL_V2"
    private let logicalKey = "BW_CRDT_HLC_LOGICAL_V2"

    public func nextStamp(observing state: BWCRDTState) -> BWCRDTStamp {
        let replicaID: String
        if let stored = defaults.string(forKey: replicaIDKey) {
            replicaID = stored
        } else {
            replicaID = UUID().uuidString.lowercased()
            defaults.set(replicaID, forKey: replicaIDKey)
        }

        let storedSequence = defaults.object(forKey: sequenceKey) as? NSNumber
        let sequence = max(
            storedSequence?.int64Value ?? 0,
            state.versionVector[replicaID] ?? 0
        ) + 1

        let wall = Int64(Date().timeIntervalSince1970 * 1_000)
        let previousPhysical = defaults.object(forKey: physicalKey) as? NSNumber
        let previousLogical = defaults.object(forKey: logicalKey) as? NSNumber
        let physical = max(
            wall,
            max(previousPhysical?.int64Value ?? 0, state.maximumStamp.physicalMilliseconds)
        )
        let logical: Int64

        if physical == (previousPhysical?.int64Value ?? -1)
            || physical == state.maximumStamp.physicalMilliseconds {
            logical = max(
                previousLogical?.int64Value ?? 0,
                state.maximumStamp.logical
            ) + 1
        } else {
            logical = 0
        }

        defaults.set(NSNumber(value: sequence), forKey: sequenceKey)
        defaults.set(NSNumber(value: physical), forKey: physicalKey)
        defaults.set(NSNumber(value: logical), forKey: logicalKey)

        return BWCRDTStamp(
            replicaID: replicaID,
            sequence: sequence,
            context: state.versionVector,
            physicalMilliseconds: physical,
            logical: logical
        )
    }
}

public enum BWCRDT {
    public static let schemaVersion = 2

    public static func migrateLegacy(_ budget: BWBudget) -> BWBudget {
        let revision = budget.revision ?? 1
        let fingerprint = legacyFingerprint(budget)
        let replicaID = "legacy:\(revision):\(fingerprint)"
        let stamp = BWCRDTStamp(
            replicaID: replicaID,
            sequence: 1,
            context: [:],
            physicalMilliseconds: 0,
            logical: revision
        )
        var migrated = budget
        migrated.schemaVersion = schemaVersion
        migrated.revision = revision
        migrated.crdt = makeState(from: budget, stamp: stamp, legacyBaseline: .init(
            revision: revision,
            fingerprint: fingerprint
        ))
        migrated.requiresCRDTWriteback = true
        return materialize(migrated)
    }

    public static func prepareNew(_ budget: BWBudget) async -> BWBudget {
        let seed = migrateLegacy(budget)
        guard let state = seed.crdt else { return seed }
        let stamp = await BWCRDTReplicaClock.shared.nextStamp(observing: state)
        var prepared = budget
        prepared.schemaVersion = schemaVersion
        prepared.revision = 1
        prepared.crdt = makeState(from: budget, stamp: stamp, legacyBaseline: nil)
        prepared.requiresCRDTWriteback = false
        return materialize(prepared)
    }

    public static func applyingChanges(from original: BWBudget, to desired: BWBudget) async -> BWBudget {
        let original = ensureState(original)
        guard var state = original.crdt else { return desired }
        let stamp = await BWCRDTReplicaClock.shared.nextStamp(observing: state)

        if original.title != desired.title {
            state.title = .init(value: desired.title, stamp: stamp)
        }

        let oldCategories = Dictionary(uniqueKeysWithValues: original.categories.map { ($0.id, $0) })
        let newCategories = Dictionary(uniqueKeysWithValues: desired.categories.map { ($0.id, $0) })

        for (id, category) in newCategories {
            let key = id.uuidString.lowercased()
            if let old = oldCategories[id], var current = state.categories[key] {
                var touched = false
                if old.ordinal != category.ordinal { current.ordinal = .init(value: category.ordinal, stamp: stamp); touched = true }
                if old.title != category.title { current.title = .init(value: category.title, stamp: stamp); touched = true }
                if old.amountPlanned != category.amountPlanned { current.amountPlanned = .init(value: category.amountPlanned, stamp: stamp); touched = true }
                if old.amountAccumulated != category.amountAccumulated { current.amountAccumulated = .init(value: category.amountAccumulated, stamp: stamp); touched = true }
                if old.categoryType != category.categoryType { current.categoryType = .init(value: category.categoryType, stamp: stamp); touched = true }
                if touched { current.presence = .init(value: true, stamp: stamp) }
                state.categories[key] = current
            } else {
                state.categories[key] = categoryState(category, stamp: stamp)
            }
        }

        for (id, old) in oldCategories where newCategories[id] == nil {
            let key = id.uuidString.lowercased()
            if var current = state.categories[key] {
                current.presence = .init(value: false, stamp: stamp)
                state.categories[key] = current
            }
            for transaction in old.transactions {
                let transactionKey = transaction.id.uuidString.lowercased()
                if var current = state.transactions[transactionKey] {
                    current.presence = .init(value: false, stamp: stamp)
                    state.transactions[transactionKey] = current
                }
            }
        }

        let oldTransactions = flattenedTransactions(original)
        let newTransactions = flattenedTransactions(desired)

        for (id, item) in newTransactions {
            let key = id.uuidString.lowercased()
            if let old = oldTransactions[id], var current = state.transactions[key] {
                var touched = false
                if old.parentID != item.parentID { current.parentCategoryID = .init(value: item.parentID, stamp: stamp); touched = true }
                if old.transaction.title != item.transaction.title { current.title = .init(value: item.transaction.title, stamp: stamp); touched = true }
                if old.transaction.description != item.transaction.description { current.description = .init(value: item.transaction.description, stamp: stamp); touched = true }
                if old.transaction.date != item.transaction.date { current.date = .init(value: item.transaction.date, stamp: stamp); touched = true }
                if old.transaction.amount != item.transaction.amount { current.amount = .init(value: item.transaction.amount, stamp: stamp); touched = true }
                if touched {
                    current.presence = .init(value: true, stamp: stamp)
                    let parentKey = item.parentID.uuidString.lowercased()
                    if var parent = state.categories[parentKey] {
                        parent.presence = .init(value: true, stamp: stamp)
                        state.categories[parentKey] = parent
                    }
                }
                state.transactions[key] = current
            } else {
                state.transactions[key] = transactionState(item.transaction, parentID: item.parentID, stamp: stamp)
            }
        }

        for id in oldTransactions.keys where newTransactions[id] == nil {
            let key = id.uuidString.lowercased()
            if var current = state.transactions[key] {
                current.presence = .init(value: false, stamp: stamp)
                state.transactions[key] = current
            }
        }

        state.versionVector[stamp.replicaID] = stamp.sequence
        state.maximumStamp = maximum(state.maximumStamp, stamp)
        var result = desired
        result.schemaVersion = schemaVersion
        result.crdt = state
        result.revision = max(state.versionVector.values.max() ?? 1, desired.revision ?? 1)
        result.requiresCRDTWriteback = false
        return materialize(result)
    }

    public static func merge(_ lhs: BWBudget, _ rhs: BWBudget) -> Result<BWBudget, BWError> {
        guard lhs.id == rhs.id else {
            return .failure(.rebaseFailed())
        }

        let lhsHasPersistedCRDT = lhs.crdt != nil && !lhs.requiresCRDTWriteback
        let rhsHasPersistedCRDT = rhs.crdt != nil && !rhs.requiresCRDTWriteback
        if lhsHasPersistedCRDT != rhsHasPersistedCRDT {
            var preferred = lhsHasPersistedCRDT ? lhs : rhs
            preferred.url = lhs.url ?? rhs.url
            preferred.requiresCRDTWriteback = false
            return .success(materialize(preferred))
        }

        let lhs = ensureState(lhs)
        let rhs = ensureState(rhs)
        guard let left = lhs.crdt, let right = rhs.crdt else {
            return .failure(.rebaseFailed())
        }

        // Also protect direct in-memory callers that construct CRDT states without
        // going through the codec and its writeback marker.
        if left.containsOnlyLegacyEvents != right.containsOnlyLegacyEvents {
            var preferred = left.containsOnlyLegacyEvents ? rhs : lhs
            preferred.url = lhs.url ?? rhs.url
            preferred.requiresCRDTWriteback = false
            return .success(materialize(preferred))
        }

        if left.containsOnlyLegacyEvents, right.containsOnlyLegacyEvents,
           let leftBaseline = left.legacyBaseline,
           let rightBaseline = right.legacyBaseline,
           leftBaseline != rightBaseline {
            return .success(leftBaseline >= rightBaseline ? lhs : rhs)
        }

        var state = left
        for (replicaID, sequence) in right.versionVector {
            state.versionVector[replicaID] = max(state.versionVector[replicaID] ?? 0, sequence)
        }
        state.maximumStamp = maximum(left.maximumStamp, right.maximumStamp)
        state.legacyBaseline = [left.legacyBaseline, right.legacyBaseline].compactMap { $0 }.max()
        state.title = left.title.merged(with: right.title)

        for (key, incoming) in right.categories {
            guard let current = state.categories[key] else {
                state.categories[key] = incoming
                continue
            }
            state.categories[key] = .init(
                presence: current.presence.mergedPresence(with: incoming.presence),
                ordinal: current.ordinal.merged(with: incoming.ordinal),
                title: current.title.merged(with: incoming.title),
                amountPlanned: current.amountPlanned.merged(with: incoming.amountPlanned),
                amountAccumulated: current.amountAccumulated.merged(with: incoming.amountAccumulated),
                categoryType: current.categoryType.merged(with: incoming.categoryType)
            )
        }

        for (key, incoming) in right.transactions {
            guard let current = state.transactions[key] else {
                state.transactions[key] = incoming
                continue
            }
            state.transactions[key] = .init(
                presence: current.presence.mergedPresence(with: incoming.presence),
                parentCategoryID: current.parentCategoryID.merged(with: incoming.parentCategoryID),
                title: current.title.merged(with: incoming.title),
                description: current.description.merged(with: incoming.description),
                date: current.date.merged(with: incoming.date),
                amount: current.amount.merged(with: incoming.amount)
            )
        }

        var result = lhs
        result.crdt = state
        result.schemaVersion = schemaVersion
        result.revision = max(
            max(lhs.revision ?? 1, rhs.revision ?? 1),
            state.versionVector.values.max() ?? 1
        )
        result.url = lhs.url ?? rhs.url
        result.requiresCRDTWriteback = false
        return .success(materialize(result))
    }

    public static func materialize(_ budget: BWBudget) -> BWBudget {
        guard let state = budget.crdt else { return budget }
        var result = budget
        result.title = state.title.value

        let aliveCategories = state.categories.compactMap { key, value -> (UUID, BWCRDTCategoryState)? in
            guard value.presence.value, let id = UUID(uuidString: key) else { return nil }
            return (id, value)
        }.sorted { lhs, rhs in
            if lhs.1.categoryType.value != rhs.1.categoryType.value {
                return lhs.1.categoryType.value.rawValue < rhs.1.categoryType.value.rawValue
            }
            if lhs.1.ordinal.value != rhs.1.ordinal.value {
                return lhs.1.ordinal.value < rhs.1.ordinal.value
            }
            if lhs.1.ordinal.stamp.totalOrder != rhs.1.ordinal.stamp.totalOrder {
                return lhs.1.ordinal.stamp.totalOrder < rhs.1.ordinal.stamp.totalOrder
            }
            return lhs.0.uuidString < rhs.0.uuidString
        }

        var ordinals: [BWCategoryType: Int] = [:]
        result.categories = aliveCategories.map { id, categoryState in
            let ordinal = ordinals[categoryState.categoryType.value, default: 0]
            ordinals[categoryState.categoryType.value] = ordinal + 1
            let transactions = state.transactions.compactMap { key, transactionState -> (BWTransaction, BWCRDTStamp)? in
                guard transactionState.presence.value,
                      transactionState.parentCategoryID.value == id,
                      let transactionID = UUID(uuidString: key)
                else { return nil }
                return (BWTransaction(
                    id: transactionID,
                    title: transactionState.title.value,
                    description: transactionState.description.value,
                    date: transactionState.date.value,
                    amount: transactionState.amount.value
                ), transactionState.presence.stamp)
            }.sorted { lhs, rhs in
                if lhs.1.totalOrder != rhs.1.totalOrder { return lhs.1.totalOrder < rhs.1.totalOrder }
                return lhs.0.id.uuidString < rhs.0.id.uuidString
            }.map(\.0)

            return BWCategory(
                id: id,
                ordinal: ordinal,
                title: categoryState.title.value,
                amountPlanned: categoryState.amountPlanned.value,
                amountActual: UInt64.sumMoneyAmounts(transactions.map(\.amount)) ?? UInt64.max,
                amountAccumulated: categoryState.amountAccumulated.value,
                categoryType: categoryState.categoryType.value,
                transactions: transactions
            )
        }
        return result
    }

    private static func ensureState(_ budget: BWBudget) -> BWBudget {
        budget.crdt == nil ? migrateLegacy(budget) : materialize(budget)
    }

    private static func makeState(
        from budget: BWBudget,
        stamp: BWCRDTStamp,
        legacyBaseline: BWCRDTLegacyBaseline?
    ) -> BWCRDTState {
        var categories: [String: BWCRDTCategoryState] = [:]
        var transactions: [String: BWCRDTTransactionState] = [:]
        for category in budget.categories {
            categories[category.id.uuidString.lowercased()] = categoryState(category, stamp: stamp)
            for transaction in category.transactions {
                transactions[transaction.id.uuidString.lowercased()] = transactionState(
                    transaction,
                    parentID: category.id,
                    stamp: stamp
                )
            }
        }
        return BWCRDTState(
            versionVector: [stamp.replicaID: stamp.sequence],
            maximumStamp: stamp,
            legacyBaseline: legacyBaseline,
            title: .init(value: budget.title, stamp: stamp),
            categories: categories,
            transactions: transactions
        )
    }

    private static func categoryState(_ category: BWCategory, stamp: BWCRDTStamp) -> BWCRDTCategoryState {
        .init(
            presence: .init(value: true, stamp: stamp),
            ordinal: .init(value: category.ordinal, stamp: stamp),
            title: .init(value: category.title, stamp: stamp),
            amountPlanned: .init(value: category.amountPlanned, stamp: stamp),
            amountAccumulated: .init(value: category.amountAccumulated, stamp: stamp),
            categoryType: .init(value: category.categoryType, stamp: stamp)
        )
    }

    private static func transactionState(
        _ transaction: BWTransaction,
        parentID: UUID,
        stamp: BWCRDTStamp
    ) -> BWCRDTTransactionState {
        .init(
            presence: .init(value: true, stamp: stamp),
            parentCategoryID: .init(value: parentID, stamp: stamp),
            title: .init(value: transaction.title, stamp: stamp),
            description: .init(value: transaction.description, stamp: stamp),
            date: .init(value: transaction.date, stamp: stamp),
            amount: .init(value: transaction.amount, stamp: stamp)
        )
    }

    private static func flattenedTransactions(
        _ budget: BWBudget
    ) -> [UUID: (parentID: UUID, transaction: BWTransaction)] {
        var result: [UUID: (UUID, BWTransaction)] = [:]
        for category in budget.categories {
            for transaction in category.transactions {
                result[transaction.id] = (category.id, transaction)
            }
        }
        return result
    }

    private static func maximum(_ lhs: BWCRDTStamp, _ rhs: BWCRDTStamp) -> BWCRDTStamp {
        lhs.totalOrder >= rhs.totalOrder ? lhs : rhs
    }

    private static func legacyFingerprint(_ budget: BWBudget) -> String {
        var text = "\(budget.id.uuidString.lowercased())|\(budget.revision ?? 1)|\(budget.title)"
        for category in budget.categories.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            text += "|c:\(category.id.uuidString.lowercased()):\(category.ordinal):\(category.title):\(category.amountPlanned):\(category.amountAccumulated):\(category.categoryType.rawValue)"
            for transaction in category.transactions.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
                let milliseconds = Int64(transaction.date.timeIntervalSince1970 * 1_000)
                text += "|t:\(transaction.id.uuidString.lowercased()):\(transaction.title):\(transaction.description):\(milliseconds):\(transaction.amount)"
            }
        }
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}
