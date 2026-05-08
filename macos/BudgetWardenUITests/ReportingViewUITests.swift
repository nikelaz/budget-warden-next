import XCTest

final class ReportingViewUITests: BudgetWardenUITestCase {
    func testReportingShowsMetricsAndSeededData() {
        createTrackedBudget(named: "Reporting View Budget")
        addCategory(type: .expenses, title: "Reporting Rent", plannedAmount: "1000")
        addTransactionFromCategoryActualCell(
            categoryTitle: "Reporting Rent",
            title: "May rent",
            amount: "1000"
        )

        openSidebarSection(.reporting)

        XCTAssertTrue(app.descendants(matching: .any)["reporting-root"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Income"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Planned Spending"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Actual Spending"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Income vs Allocation"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Allocation Breakdown"].waitForExistence(timeout: 5))
        XCTAssertTrue(categoryTitleCell("Reporting Rent").waitForExistence(timeout: 5))
    }
}
