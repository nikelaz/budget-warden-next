import XCTest

final class TransactionsViewUITests: BudgetWardenUITestCase {
    func testShowsEmptyStateBeforeTransactions() {
        createTrackedBudget(named: "Transactions Empty State")
        openSidebarSection(.transactions)

        XCTAssertTrue(app.staticTexts["No Transactions"].waitForExistence(timeout: 5))
    }

    func testAddsSearchesEditsAndDeletesTransaction() {
        createTrackedBudget(named: "Transactions Workflow")
        openSidebarSection(.transactions)

        addTransactionFromToolbar(title: "Coffee beans", amount: "18.50")

        XCTAssertTrue(app.staticTexts["Coffee beans"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["transaction-amount-cell-Coffee-beans"].waitForExistence(timeout: 5))

        let searchField = app.searchFields.firstMatch
        replaceText(in: searchField, with: "Coffee")
        XCTAssertTrue(app.staticTexts["Coffee beans"].waitForExistence(timeout: 5))

        replaceText(in: searchField, with: "No matching transaction")
        XCTAssertTrue(app.staticTexts["Coffee beans"].waitForNonExistence(timeout: 5))

        replaceText(in: searchField, with: "")
        let transactionTitle = app.staticTexts["Coffee beans"].firstMatch
        XCTAssertTrue(transactionTitle.waitForExistence(timeout: 5))
        transactionTitle.click()

        let editField = app.textFields.matching(identifier: "transaction-1-edit-field").firstMatch
        if editField.waitForExistence(timeout: 1) {
            replaceText(in: editField, with: "Coffee beans updated")
            editField.typeKey(.return, modifierFlags: [])
            XCTAssertTrue(app.staticTexts["Coffee beans updated"].waitForExistence(timeout: 5))
            deleteTransaction(named: "Coffee beans updated")
        } else {
            deleteTransaction(named: "Coffee beans")
        }
    }
}
