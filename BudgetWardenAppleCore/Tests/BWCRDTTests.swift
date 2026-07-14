import Foundation
import Testing
@testable import BudgetWardenAppleCore

struct BWCRDTTests {
    @Test func decodedCRDTStateIsPreserved() throws {
        let original = BWCRDT.migrateLegacy(makeBudget())
        let json = try BWCodec.encodeBudget(budget: original).get()

        let decoded = try BWCodec.decodeBudget(
            json: json,
            url: URL(fileURLWithPath: "/Decoded.budget")
        ).get()

        #expect(decoded.crdt == original.crdt)
        #expect(decoded.title == original.title)
    }

    @Test func schemaTwoWithoutCRDTLoadsAsLegacySnapshot() throws {
        var legacy = makeBudget()
        legacy.schemaVersion = BWCRDT.schemaVersion
        let json = try BWCodec.encodeBudget(budget: legacy).get()

        let decoded = try BWCodec.decodeBudget(
            json: json,
            url: URL(fileURLWithPath: "/Legacy.budget")
        ).get()

        #expect(decoded.crdt != nil)
        #expect(decoded.requiresCRDTWriteback)
    }

    @Test func CRDTDocumentWinsOverLegacySnapshot() throws {
        let legacy = BWCRDT.migrateLegacy(makeBudget())
        var edited = BWCRDT.migrateLegacy(makeBudget())
        var state = try #require(edited.crdt)
        state.title = .init(value: "CRDT title", stamp: stamp(actor: "apple", sequence: 1))
        state.versionVector = ["apple": 1]
        state.maximumStamp = stamp(actor: "apple", sequence: 1)
        state.legacyBaseline = nil
        edited.crdt = state
        edited.requiresCRDTWriteback = false
        edited = BWCRDT.materialize(edited)

        let merged = try BWCRDT.merge(legacy, edited).get()

        #expect(merged.title == "CRDT title")
        #expect(merged.crdt == edited.crdt)
    }

    @Test func deletedCategoryDoesNotReappearAfterReloadAndMerge() async throws {
        let original = await BWCRDT.prepareNew(makeBudget())
        let categoryID = try #require(original.categories.first?.id)
        let categoryKey = categoryID.uuidString.lowercased()
        let originalJSON = try BWCodec.encodeBudget(budget: original).get()
        let staleSnapshot = try BWCodec.decodeBudget(
            json: originalJSON,
            url: URL(fileURLWithPath: "/Stale.budget")
        ).get()

        var desired = staleSnapshot
        desired.categories.removeAll(where: { $0.id == categoryID })
        let deleted = await BWCRDT.applyingChanges(from: staleSnapshot, to: desired)
        let deletedJSON = try BWCodec.encodeBudget(budget: deleted).get()
        let reloadedDeletion = try BWCodec.decodeBudget(
            json: deletedJSON,
            url: URL(fileURLWithPath: "/Deleted.budget")
        ).get()

        let merged = try BWCRDT.merge(reloadedDeletion, staleSnapshot).get()

        #expect(merged.categories.allSatisfy { $0.id != categoryID })
        #expect(merged.crdt?.categories[categoryKey]?.presence.value == false)
    }

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

    @Test func categoryReorderRebasesOntoLatestCRDTState() async throws {
        let base = await BWCRDT.prepareNew(makeOrderedBudget())
        let firstCategoryID = try #require(base.categories.first?.id)
        let movedCategoryID = try #require(base.categories.last?.id)

        var remoteDesired = base
        remoteDesired.categories[0].title = "Remote title"
        let remote = await BWCRDT.applyingChanges(from: base, to: remoteDesired)

        var staleReorder = base
        staleReorder.categories[2].ordinal = 3
        staleReorder.categories[3].ordinal = 2
        let categoryIDs = staleReorder.categories.map(\.id)

        let rebased = try BWRebase.rebase(
            budgetInMemory: staleReorder,
            onto: remote,
            operation: .CategoriesBulkOrdinalUpdate(categoryIds: categoryIDs)
        ).get()
        let original = BWCRDT.materialize(rebased)
        let saved = await BWCRDT.applyingChanges(from: original, to: rebased)
        let merged = try BWCRDT.merge(saved, remote).get()

        #expect(merged.categories.map(\.id) == [
            base.categories[0].id,
            base.categories[1].id,
            movedCategoryID,
            base.categories[2].id
        ])
        #expect(merged.categories.first(where: { $0.id == firstCategoryID })?.title == "Remote title")
    }

    @Test func repeatedCategoryMovesUpdateOrdinalsInMemory() throws {
        var budget = makeOrderedBudget()
        let movedCategory = try #require(budget.categories.last)

        for _ in 0..<3 {
            budget = try BWBudgetService.prepareCategoryMove(
                movedCategory,
                in: budget,
                by: -1
            ).get()
        }

        #expect(budget.orderedCategories(for: .expenses).map(\.id).first == movedCategory.id)
        #expect(budget.orderedCategories(for: .expenses).map(\.ordinal) == [0, 1, 2, 3])
    }

    @Test func queuedCategoryReordersPersistTheFinalPosition() async throws {
        let base = await BWCRDT.prepareNew(makeOrderedBudget())
        let movedCategory = try #require(base.categories.last)
        let categoryIDs = base.categories.map(\.id)
        var optimisticBudget = base
        var persistedBudget = base

        for _ in 0..<3 {
            optimisticBudget = try BWBudgetService.prepareCategoryMove(
                movedCategory,
                in: optimisticBudget,
                by: -1
            ).get()
            let rebased = try BWRebase.rebase(
                budgetInMemory: optimisticBudget,
                onto: persistedBudget,
                operation: .CategoriesBulkOrdinalUpdate(categoryIds: categoryIDs)
            ).get()
            let original = BWCRDT.materialize(rebased)
            let saved = await BWCRDT.applyingChanges(from: original, to: rebased)
            persistedBudget = try BWCRDT.merge(saved, persistedBudget).get()
        }

        #expect(persistedBudget.orderedCategories(for: .expenses).map(\.id).first == movedCategory.id)
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

    private func makeOrderedBudget() -> BWBudget {
        BWBudget(
            title: "Budget",
            categories: (0..<4).map { ordinal in
                BWCategory(
                    ordinal: ordinal,
                    title: "Category \(ordinal)",
                    amountPlanned: UInt64(ordinal + 1) * 1_000,
                    categoryType: .expenses
                )
            }
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
