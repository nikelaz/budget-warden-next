import XCTest

final class WelcomeWindowUITests: BudgetWardenUITestCase {
    func testShowsPrimaryActions() {
        XCTAssertTrue(app.staticTexts["Budget Warden"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Create New Budget"].exists)
        XCTAssertTrue(app.buttons["Open Budget"].exists)
        XCTAssertTrue(app.buttons["Configure Vault"].exists)
    }

    func testCreateBudgetDialogCanBeCancelled() {
        app.buttons["Create New Budget"].click()

        XCTAssertTrue(app.staticTexts["New Budget"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["budget-title-field"].exists)

        app.buttons["Cancel"].click()
        XCTAssertTrue(app.buttons["Create New Budget"].waitForExistence(timeout: 5))
    }

    func testCreatesBudgetAndOpensWorkspace() {
        createTrackedBudget(named: "Welcome Create Budget")

        XCTAssertTrue(app.staticTexts["Income"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Expenses"].exists)
    }

    func testPersistsReopensAndDeletesBudgetFromWelcome() {
        createTrackedBudget(named: "Welcome Persist Budget")
        addCategory(type: .income, title: "Consulting", plannedAmount: "2500")

        relaunchToWelcome()

        let budgetRow = app.buttons["budget-row-Welcome Persist Budget"].firstMatch
        XCTAssertTrue(budgetRow.waitForExistence(timeout: 5))
        budgetRow.click()

        XCTAssertTrue(app.staticTexts["Income"].waitForExistence(timeout: 5))
        XCTAssertTrue(categoryTitleCell("Consulting").waitForExistence(timeout: 5))

        relaunchToWelcome()
        removeTrackedBudgetFromWelcome(named: "Welcome Persist Budget")
    }

    func testCancelDeleteKeepsBudgetThenDeleteRemovesIt() {
        createTrackedBudget(named: "Welcome Cancel Delete Budget")
        relaunchToWelcome()

        let budgetRow = app.buttons["budget-row-Welcome Cancel Delete Budget"].firstMatch
        XCTAssertTrue(budgetRow.waitForExistence(timeout: 5))
        budgetRow.rightClick()

        let removeMenuItem = app.menuItems["Remove from Vault"]
        XCTAssertTrue(removeMenuItem.waitForExistence(timeout: 5))
        removeMenuItem.click()

        let cancelButton = app.windows.sheets.buttons["Cancel"].firstMatch
        XCTAssertTrue(cancelButton.waitForExistence(timeout: 5))
        cancelButton.click()
        XCTAssertTrue(budgetRow.waitForExistence(timeout: 5))

        removeTrackedBudgetFromWelcome(named: "Welcome Cancel Delete Budget")
    }
}
