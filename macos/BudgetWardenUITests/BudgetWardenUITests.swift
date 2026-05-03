import XCTest

final class BudgetWardenUITests: XCTestCase {
    private var app: XCUIApplication!
    private var testRunID: String!

    override func setUpWithError() throws {
        continueAfterFailure = false
        testRunID = UUID().uuidString
        app = launchApp(testRunID: testRunID)
    }

    override func tearDownWithError() throws {
        app?.terminate()

        app = nil
        testRunID = nil
    }

    func testWelcomeWindowShowsPrimaryActions() {
        XCTAssertTrue(app.staticTexts["Budget Warden"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["welcome-create-budget-button"].exists)
        XCTAssertTrue(app.buttons["welcome-open-budget-button"].exists)
        XCTAssertTrue(app.buttons["welcome-configure-vault-button"].exists)
    }

    func testCreateBudgetAddCategoryAndTransaction() {
        createBudget(named: "UI Smoke Budget")

        XCTAssertTrue(app.staticTexts["Income"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Expenses"].exists)
        XCTAssertTrue(app.staticTexts["No categories"].exists)

        addCategory(buttonTitle: "New Income", title: "Salary", plannedAmount: "5000")
        addCategory(buttonTitle: "New Category", title: "Rent", plannedAmount: "1200")

        XCTAssertTrue(app.staticTexts["Salary"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Rent"].waitForExistence(timeout: 5))

        openSidebarSection("Transactions")
        XCTAssertTrue(app.staticTexts["No Transactions"].waitForExistence(timeout: 5))

        app.buttons["Add Transaction"].click()
        replaceText(in: app.textFields["transaction-title-field"], with: "May paycheck")
        replaceText(in: app.textFields["transaction-amount-field"], with: "5000")
        app.buttons["Save"].click()

        XCTAssertTrue(app.staticTexts["May paycheck"].waitForExistence(timeout: 5))

        openSidebarSection("Reporting")
        XCTAssertTrue(app.staticTexts["Reporting"].waitForExistence(timeout: 5))

        openSidebarSection("Budget")
        XCTAssertTrue(app.staticTexts["Salary"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Rent"].exists)
    }

    func testBudgetPersistsAndCanBeReopenedFromWelcomeWindow() {
        createBudget(named: "Persistent Budget")
        addCategory(buttonTitle: "New Income", title: "Consulting", plannedAmount: "2500")

        app.terminate()
        app = launchApp(testRunID: testRunID)

        let budgetRow = app.buttons["budget-row-Persistent Budget"]
        XCTAssertTrue(budgetRow.waitForExistence(timeout: 5))
        budgetRow.click()

        XCTAssertTrue(app.staticTexts["Income"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Consulting"].waitForExistence(timeout: 5))
    }

    private func launchApp(testRunID: String) -> XCUIApplication {
        let launchedApp = XCUIApplication()
        launchedApp.launchArguments = [
            "-ApplePersistenceIgnoreState", "YES"
        ]
        launchedApp.launchEnvironment = [
            "BUDGET_WARDEN_UI_TEST_RUN_ID": testRunID,
            "AppleLanguages": "(en)",
            "AppleLocale": "en_US"
        ]
        launchedApp.launch()
        focusWelcomeWindow(in: launchedApp)
        return launchedApp
    }

    private func focusWelcomeWindow(in launchedApp: XCUIApplication) {
        let welcomeButton = launchedApp.buttons["welcome-create-budget-button"]
        XCTAssertTrue(welcomeButton.waitForExistence(timeout: 5))

        let welcomeWindow = launchedApp.windows
            .containing(.button, identifier: "welcome-create-budget-button")
            .firstMatch

        if welcomeWindow.exists {
            welcomeWindow.click()
        }
    }

    private func createBudget(named title: String) {
        app.buttons["welcome-create-budget-button"].click()
        replaceText(in: app.textFields["budget-title-field"], with: title)
        app.buttons["Save"].click()
        XCTAssertTrue(app.staticTexts["Income"].waitForExistence(timeout: 5))
    }

    private func addCategory(buttonTitle: String, title: String, plannedAmount: String) {
        app.buttons[buttonTitle].click()
        let titleField = app.textFields["new-category-title-field"]
        XCTAssertTrue(titleField.waitForExistence(timeout: 5))
        replaceText(in: titleField, with: title)

        let plannedField = app.textFields["new-category-planned-field"]
        XCTAssertTrue(plannedField.waitForExistence(timeout: 5))
        replaceText(in: plannedField, with: plannedAmount)
        plannedField.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 5))
    }

    private func openSidebarSection(_ title: String) {
        let section = app.staticTexts[title].firstMatch
        XCTAssertTrue(section.waitForExistence(timeout: 5))
        section.click()
    }

    private func replaceText(in element: XCUIElement, with text: String) {
        XCTAssertTrue(element.waitForExistence(timeout: 5))
        element.click()
        element.typeKey("a", modifierFlags: [.command])
        element.typeText(text)
    }

}
