import XCTest
@testable import BudgetWarden

final class BudgetDocumentTests: XCTestCase {
    func testIdentityUsesURLNotCoreID() {
        let first = BudgetDocument(
            coreID: 1,
            url: URL(fileURLWithPath: "/tmp/First.budget"),
            title: "First",
            categories: []
        )
        let second = BudgetDocument(
            coreID: 1,
            url: URL(fileURLWithPath: "/tmp/Second.budget"),
            title: "Second",
            categories: []
        )

        XCTAssertEqual(first.coreID, second.coreID)
        XCTAssertNotEqual(first.id, second.id)
    }

    func testCategoriesForTypeFiltersAndSortsByOrdinalThenCoreID() {
        let incomeLast = category(coreID: 30, ordinal: 2, title: "Bonus", type: .income)
        let expense = category(coreID: 10, ordinal: 1, title: "Rent", type: .expenses)
        let incomeSecond = category(coreID: 20, ordinal: 1, title: "Freelance", type: .income)
        let incomeFirst = category(coreID: 5, ordinal: 1, title: "Salary", type: .income)
        let budget = document(categories: [incomeLast, expense, incomeSecond, incomeFirst])

        XCTAssertEqual(
            budget.categories(for: .income).map(\.coreID),
            [5, 20, 30]
        )
    }

    func testTransactionsAreFlattenedAndSortedNewestFirst() {
        let olderHigherID = transaction(coreID: 99, title: "Old high ID", date: date(year: 2024, month: 12, day: 31))
        let newestLowerID = transaction(coreID: 1, title: "Newest low ID", date: date(year: 2025, month: 1, day: 2))
        let newestHigherID = transaction(coreID: 2, title: "Newest high ID", date: date(year: 2025, month: 1, day: 2))
        let previousDay = transaction(coreID: 100, title: "Previous day", date: date(year: 2025, month: 1, day: 1))
        let budget = document(
            categories: [
                category(coreID: 1, ordinal: 1, title: "Income", type: .income, transactions: [olderHigherID, newestLowerID]),
                category(coreID: 2, ordinal: 1, title: "Expenses", type: .expenses, transactions: [newestHigherID, previousDay])
            ]
        )

        XCTAssertEqual(
            budget.transactions.map(\.title),
            ["Newest high ID", "Newest low ID", "Previous day", "Old high ID"]
        )
    }

    func testTransactionFormattedDatePadsMonthAndDay() {
        let transaction = transaction(coreID: 1, title: "Transfer", date: date(year: 2026, month: 5, day: 7))

        XCTAssertEqual(transaction.formattedDate, "2026-05-07")
    }

    func testCategoryTypeMapsToAndFromCoreType() {
        for type in BudgetCategoryType.allCases {
            XCTAssertEqual(BudgetCategoryType(coreType: type.coreType), type)
        }
    }

    private func document(categories: [BudgetCategory]) -> BudgetDocument {
        BudgetDocument(
            coreID: 1,
            url: URL(fileURLWithPath: "/tmp/Test.budget"),
            title: "Test",
            categories: categories
        )
    }

    private func category(
        coreID: Int,
        ordinal: Int,
        title: String,
        type: BudgetCategoryType,
        transactions: [BudgetTransaction] = []
    ) -> BudgetCategory {
        BudgetCategory(
            id: "\(type)-\(coreID)",
            coreID: coreID,
            ordinal: ordinal,
            title: title,
            amountPlanned: 0,
            amountActual: 0,
            amountAccumulated: 0,
            type: type,
            transactions: transactions
        )
    }

    private func transaction(coreID: Int, title: String, date: BWDate) -> BudgetTransaction {
        BudgetTransaction(
            id: "transaction-\(coreID)",
            coreID: coreID,
            title: title,
            description: "",
            date: date,
            amount: 0,
            categoryID: 1,
            categoryTitle: "Category",
            categoryType: .expenses
        )
    }

    private func date(year: Int32, month: Int32, day: Int32) -> BWDate {
        BWDate(year: year, month: month, day: day)
    }
}
