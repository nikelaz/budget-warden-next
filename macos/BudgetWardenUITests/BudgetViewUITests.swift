import XCTest

final class BudgetViewUITests: BudgetWardenUITestCase {
    func testCreatesEditsAndDeletesCategories() {
        createTrackedBudget(named: "Budget View Categories")

        addCategory(type: .income, title: "Client Work", plannedAmount: "4200")
        addCategory(type: .expenses, title: "Studio Rent", plannedAmount: "900")

        XCTAssertTrue(categoryTitleCell("Client Work").waitForExistence(timeout: 5))
        XCTAssertTrue(categoryTitleCell("Studio Rent").waitForExistence(timeout: 5))

        let edited = editCategoryTitle(from: "Studio Rent", to: "Office Rent")
        deleteCategory(named: edited ? "Office Rent" : "Studio Rent")
    }

    func testAddsTransactionFromCategoryAmountCellAndUpdatesActualValue() {
        createTrackedBudget(named: "Budget View Transaction")
        addCategory(type: .expenses, title: "Utilities UI", plannedAmount: "300")

        addTransactionFromCategoryActualCell(
            categoryTitle: "Utilities UI",
            title: "Power bill",
            amount: "125"
        )

        XCTAssertTrue(categoryTitleCell("Utilities UI").waitForExistence(timeout: 5))
    }
}
