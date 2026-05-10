import XCTest
@testable import BudgetWarden

final class BudgetModelTests: XCTestCase {
    @MainActor
        func testBudgetStorePersistsBridgeBackedRowsTotalsAndTransactions() throws {
            let store = BudgetStore()
            store.createBudget(BudgetDraft(title: "Store Coverage", templateURL: nil))

            XCTAssertNil(store.presentedError)
            XCTAssertEqual(store.selectedBudgetRow?.title, "Store Coverage")
            XCTAssertEqual(store.budgets.map(\.title), ["Store Coverage"])

            store.addCategory(title: "Salary", amountPlanned: 300_000, amountAccumulated: 0, type: .income)
            store.addCategory(title: "Rent", amountPlanned: 100_000, amountAccumulated: 0, type: .expenses)
            store.addCategory(title: "Groceries", amountPlanned: 40_000, amountAccumulated: 0, type: .expenses)
            store.addCategory(title: "Emergency Fund", amountPlanned: 50_000, amountAccumulated: 12_500, type: .savings)

            let expenseIDs = store.categoryIDs(for: .expenses)
            XCTAssertEqual(expenseIDs.map { store.category($0)?.title.swiftString() ?? "" }, ["Rent", "Groceries"])
            XCTAssertEqual(store.categoryIDs().map { store.category($0)?.title.swiftString() ?? "" }, [
                "Salary",
                "Rent",
                "Groceries",
                "Emergency Fund"
            ])
            XCTAssertEqual(store.categoryTotal(type: .expenses, field: .planned), 140_000)
            XCTAssertEqual(store.category(store.categoryIDs(for: .savings)[0])?.amount_accumulated, 12_500)

            store.addTransaction(TransactionDraft(
                categoryID: expenseIDs[0],
                title: "May rent",
                description: "Apartment",
                date: BWDate(year: 2026, month: 5, day: 1),
                amount: 100_000
            ))
            store.addTransaction(TransactionDraft(
                categoryID: expenseIDs[1],
                title: "Market",
                description: "",
                date: BWDate(year: 2026, month: 5, day: 7),
                amount: 8_750
            ))

            let transactionIDs = store.transactionIDs()
            XCTAssertEqual(transactionIDs.map { store.transaction($0)?.title.swiftString() ?? "" }, ["Market", "May rent"])
            XCTAssertEqual(store.transaction(transactionIDs[0])?.category_title.swiftString(), "Groceries")
            XCTAssertEqual(store.transaction(transactionIDs[1])?.description.swiftString(), "Apartment")
            XCTAssertEqual(store.transaction(transactionIDs[0])?.date.formattedDate, "2026-05-07")
            XCTAssertEqual(store.categoryTotal(type: .expenses, field: .actual), 108_750)

            store.updateTransaction(TransactionUpdate(
                transactionID: transactionIDs[0],
                categoryID: expenseIDs[0],
                title: "Market run",
                description: "Moved to rent bucket",
                date: BWDate(year: 2026, month: 5, day: 8),
                amount: 9_250
            ))

            XCTAssertEqual(store.transactionIDs().map { store.transaction($0)?.title.swiftString() ?? "" }, ["Market run", "May rent"])
            XCTAssertEqual(store.transaction(transactionIDs[0])?.category_title.swiftString(), "Rent")
            XCTAssertEqual(store.categoryTotal(type: .expenses, field: .actual), 109_250)

            let reloadedStore = BudgetStore()
            reloadedStore.loadBudgets()

        XCTAssertNil(reloadedStore.presentedError)
        XCTAssertEqual(reloadedStore.selectedBudgetRow?.title, "Store Coverage")
        XCTAssertEqual(reloadedStore.categoryIDs().map { reloadedStore.category($0)?.title.swiftString() ?? "" }, [
            "Salary",
            "Rent",
            "Groceries",
            "Emergency Fund"
        ])
        XCTAssertEqual(reloadedStore.transactionIDs().map { reloadedStore.transaction($0)?.title.swiftString() ?? "" }, [
            "Market run",
            "May rent"
        ])
    }

    func testBudgetRowIdentityUsesURLNotCoreID() {
        let first = BudgetRow(
            url: URL(fileURLWithPath: "/tmp/First.budget"),
            coreID: 1,
            title: "First"
        )
        let second = BudgetRow(
            url: URL(fileURLWithPath: "/tmp/Second.budget"),
            coreID: 1,
            title: "Second"
        )

        XCTAssertEqual(first.coreID, second.coreID)
        XCTAssertNotEqual(first.id, second.id)
    }

    func testCategoryTypeMapsToAndFromCoreType() {
        for type in BudgetCategoryType.allCases {
            XCTAssertEqual(BudgetCategoryType(coreType: type.coreType), type)
        }
    }

    func testCategoryAmountFieldMapsToCoreField() {
        XCTAssertEqual(CategoryAmountField.planned.coreField, BW_CATEGORY_AMOUNT_PLANNED)
        XCTAssertEqual(CategoryAmountField.actual.coreField, BW_CATEGORY_AMOUNT_ACTUAL)
        XCTAssertEqual(CategoryAmountField.accumulated.coreField, BW_CATEGORY_AMOUNT_ACCUMULATED)
    }

    func testCoreDateFormattedDatePadsMonthAndDay() {
        let date = BWDate(year: 2026, month: 5, day: 7)

        XCTAssertEqual(date.formattedDate, "2026-05-07")
    }

    func testOptionalCStringUsesFallbackForMissingValue() {
        let missing: UnsafePointer<CChar>? = nil

        XCTAssertEqual(missing.swiftString(default: "Untitled"), "Untitled")
        XCTAssertEqual("Budget".withCString { Optional($0).swiftString() }, "Budget")
    }
}
