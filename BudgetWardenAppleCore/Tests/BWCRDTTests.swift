import Foundation
import Testing
@testable import BudgetWardenAppleCore

struct BWCRDTTests {
    @Test func mergeIsCommutativeAndIdempotent() throws {
        let base = BWCRDT.migrateLegacy(makeBudget())
        var left = base
        var right = base
        let categoryID = try #require(base.categories.first?.id)
        let key = categoryID.uuidString.lowercased()

        var leftState = try #require(left.crdt)
        var leftCategory = try #require(leftState.categories[key])
        leftCategory.title = .init(value: "Housing", stamp: stamp(actor: "left", sequence: 1))
        leftCategory.presence = .init(value: true, stamp: stamp(actor: "left", sequence: 1))
        leftState.categories[key] = leftCategory
        leftState.versionVector["left"] = 1
        left.crdt = leftState

        var rightState = try #require(right.crdt)
        var rightCategory = try #require(rightState.categories[key])
        rightCategory.amountPlanned = .init(value: 90_000, stamp: stamp(actor: "right", sequence: 1))
        rightCategory.presence = .init(value: true, stamp: stamp(actor: "right", sequence: 1))
        rightState.categories[key] = rightCategory
        rightState.versionVector["right"] = 1
        right.crdt = rightState

        let leftRight = try BWCRDT.merge(left, right).get()
        let rightLeft = try BWCRDT.merge(right, left).get()
        let repeated = try BWCRDT.merge(leftRight, leftRight).get()

        #expect(leftRight.crdt == rightLeft.crdt)
        #expect(leftRight.crdt == repeated.crdt)
        #expect(leftRight.categories[0].title == "Housing")
        #expect(leftRight.categories[0].amountPlanned == 90_000)
    }

    @Test func concurrentDeleteWinsOverEdit() throws {
        let base = BWCRDT.migrateLegacy(makeBudget())
        let transactionID = try #require(base.categories.first?.transactions.first?.id)
        let key = transactionID.uuidString.lowercased()
        var deleted = base
        var edited = base

        var deletedState = try #require(deleted.crdt)
        var deletedTransaction = try #require(deletedState.transactions[key])
        deletedTransaction.presence = .init(value: false, stamp: stamp(actor: "delete", sequence: 1))
        deletedState.transactions[key] = deletedTransaction
        deletedState.versionVector["delete"] = 1
        deleted.crdt = deletedState

        var editedState = try #require(edited.crdt)
        var editedTransaction = try #require(editedState.transactions[key])
        editedTransaction.amount = .init(value: 99_00, stamp: stamp(actor: "edit", sequence: 1))
        editedTransaction.presence = .init(value: true, stamp: stamp(actor: "edit", sequence: 1))
        editedState.transactions[key] = editedTransaction
        editedState.versionVector["edit"] = 1
        edited.crdt = editedState

        let merged = try BWCRDT.merge(deleted, edited).get()
        #expect(merged.categories[0].transactions.isEmpty)
        #expect(merged.crdt?.transactions[key]?.presence.value == false)
    }

    @Test func higherLegacyRevisionWinsWholeSnapshot() throws {
        let id = UUID()
        let older = BWCRDT.migrateLegacy(BWBudget(id: id, title: "Older"))
        var newerBudget = BWBudget(id: id, title: "Newer")
        newerBudget.revision = 9
        let newer = BWCRDT.migrateLegacy(newerBudget)

        let merged = try BWCRDT.merge(older, newer).get()
        #expect(merged.title == "Newer")
        #expect(merged.revision == 9)
    }

    private func makeBudget() -> BWBudget {
        BWBudget(
            title: "Budget",
            categories: [BWCategory(
                title: "Rent",
                amountPlanned: 80_000,
                categoryType: .expenses,
                transactions: [BWTransaction(title: "Payment", date: Date(timeIntervalSince1970: 1), amount: 80_000)]
            )]
        )
    }

    private func stamp(actor: String, sequence: Int64) -> BWCRDTStamp {
        BWCRDTStamp(
            replicaID: actor,
            sequence: sequence,
            context: [:],
            physicalMilliseconds: sequence,
            logical: 0
        )
    }
}
