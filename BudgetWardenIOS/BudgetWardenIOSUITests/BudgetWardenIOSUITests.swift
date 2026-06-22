/*
 * Budget Warden
 * Copyright (c) 2026 Lazarov & Co EOOD
 * Author: Nikola Lazarov
 *
 * Licensed under the Source-Available Educational License.
 * See the LICENSE file in the project root for full terms.
 *
 */

import XCTest

final class BudgetWardenIOSUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testBudgetListUI() {
        let app = launchApp(resetState: true)

        XCTAssertTrue(app.navigationBars["Budgets"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["No Budgets"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["addBudgetButton"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["vaultButton"].waitForExistence(timeout: 5))

        app.terminate()
    }

    func testCreateNewBudgetFromList() {
        let budgetName = "iOS Test Budget \(UUID().uuidString.prefix(8))"
        let app = launchApp(resetState: true)

        createBudget(app: app, budgetName: budgetName)

        for category in [
            "Salary",
            "Food",
            "Housing",
            "Emergency Fund",
            "Retirement",
            "Fun & Entertainment",
            "Health & Fitness"
        ] {
            assertCategoryExists(app: app, title: category)
        }

        openBudgetList(app: app)

        app.terminate()
        app.launchArguments = uiTestLaunchArguments(resetState: false)
        app.launch()

        XCTAssertTrue(app.buttons["budgetRow_\(budgetName)"].waitForExistence(timeout: 5))
        deleteBudgetFromList(app: app, budgetName: budgetName)

        app.terminate()
    }

    func testCategoryCreateEditDelete() {
        let suffix = String(UUID().uuidString.prefix(8))
        let budgetName = "iOS Category Budget \(suffix)"
        let categoryTitle = "iOS Category \(suffix)"
        let updatedCategoryTitle = "iOS Category Updated \(suffix)"
        let app = launchApp(resetState: true)

        createBudget(app: app, budgetName: budgetName)
        createCategory(app: app, title: categoryTitle, plannedAmount: "123.45")
        assertCategoryAmount(app: app, title: categoryTitle, amount: "$123.45")

        openCategoryEditor(app: app, title: categoryTitle)
        replaceText(in: app.textFields["categoryTitleTextField"], with: updatedCategoryTitle)
        replaceText(in: app.textFields["categoryPlannedTextField"], with: "456.78")
        tapButton(app.buttons["categorySaveButton"])

        assertCategoryAmount(app: app, title: updatedCategoryTitle, amount: "$456.78")

        openCategoryEditor(app: app, title: updatedCategoryTitle)
        tapButton(app.buttons["categoryEditorDeleteButton"])
        tapButton(app.buttons["categoryEditorDeleteConfirmButton"])

        XCTAssertFalse(app.buttons["categoryRow_\(updatedCategoryTitle)"].waitForExistence(timeout: 5))

        app.terminate()
    }

    func testTransactionCreateAndActualAmount() {
        let suffix = String(UUID().uuidString.prefix(8))
        let budgetName = "iOS Transaction Budget \(suffix)"
        let transactionTitle = "iOS Salary Transaction \(suffix)"
        let app = launchApp(resetState: true)

        createBudget(app: app, budgetName: budgetName)
        createTransaction(
            app: app,
            categoryTitle: "Salary",
            transactionTitle: transactionTitle,
            amount: "123.45"
        )

        openBudgetTab(app: app)
        tapButton(app.buttons["Actual"])
        assertCategoryAmount(app: app, title: "Salary", amount: "$123.45")

        openTransactionsTab(app: app)
        XCTAssertTrue(app.buttons["transactionRow_\(transactionTitle)"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["transactionCategory_\(transactionTitle)"].waitForExistence(timeout: 5))
        assertStaticTextValue(app.staticTexts["transactionAmount_\(transactionTitle)"], equals: "$123.45")

        app.terminate()
    }

    func testBudgetSwitchingAndPersistence() {
        let suffix = String(UUID().uuidString.prefix(8))
        let firstBudgetName = "iOS Budget One \(suffix)"
        let secondBudgetName = "iOS Budget Two \(suffix)"
        let firstMarker = "First Marker \(suffix)"
        let secondMarker = "Second Marker \(suffix)"
        let app = launchApp(resetState: true)

        createBudget(app: app, budgetName: firstBudgetName)
        createCategory(app: app, title: firstMarker, plannedAmount: "101.01")

        openBudgetList(app: app)
        createBudget(app: app, budgetName: secondBudgetName)
        createCategory(app: app, title: secondMarker, plannedAmount: "202.02")

        openBudgetList(app: app)
        openBudget(app: app, budgetName: firstBudgetName)
        assertCategoryAmount(app: app, title: firstMarker, amount: "$101.01")
        XCTAssertFalse(app.buttons["categoryRow_\(secondMarker)"].waitForExistence(timeout: 2))

        app.terminate()
        app.launchArguments = uiTestLaunchArguments(resetState: false)
        app.launch()

        openBudget(app: app, budgetName: secondBudgetName)
        assertCategoryAmount(app: app, title: secondMarker, amount: "$202.02")
        XCTAssertFalse(app.buttons["categoryRow_\(firstMarker)"].waitForExistence(timeout: 2))

        app.terminate()
    }

    private func launchApp(resetState: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = uiTestLaunchArguments(resetState: resetState)
        app.launch()
        return app
    }

    private func uiTestLaunchArguments(resetState: Bool) -> [String] {
        var arguments = ["-BWUITesting"]

        if resetState {
            arguments.append("-BWResetUITestState")
        }

        return arguments
    }

    private func createBudget(app: XCUIApplication, budgetName: String) {
        tapButton(app.buttons["addBudgetButton"])

        let titleInput = app.textFields["createBudgetTitleTextField"]
        XCTAssertTrue(titleInput.waitForExistence(timeout: 5))
        replaceText(in: titleInput, with: budgetName)

        tapButton(app.buttons["createBudgetSaveButton"])
        XCTAssertTrue(app.navigationBars[budgetName].waitForExistence(timeout: 5))
        assertCategoryExists(app: app, title: "Emergency Fund")
    }

    private func openBudget(app: XCUIApplication, budgetName: String) {
        let budgetRow = app.buttons["budgetRow_\(budgetName)"]
        XCTAssertTrue(budgetRow.waitForExistence(timeout: 5))
        budgetRow.tap()
        XCTAssertTrue(app.navigationBars[budgetName].waitForExistence(timeout: 5))
    }

    private func openBudgetList(app: XCUIApplication) {
        let allBudgetsButton = app.buttons["allBudgetsButton"]

        XCTAssertTrue(allBudgetsButton.waitForExistence(timeout: 5))
        allBudgetsButton.tap()

        XCTAssertTrue(app.navigationBars["Budgets"].waitForExistence(timeout: 5))
    }

    private func deleteBudgetFromList(app: XCUIApplication, budgetName: String) {
        let budgetRow = app.buttons["budgetRow_\(budgetName)"]
        XCTAssertTrue(budgetRow.waitForExistence(timeout: 5))
        budgetRow.swipeLeft()
        tapButton(app.buttons["Delete"])
        tapButton(app.buttons["budgetDeleteConfirmButton"])
        XCTAssertFalse(budgetRow.waitForExistence(timeout: 5))
    }

    private func createCategory(app: XCUIApplication, title: String, plannedAmount: String) {
        openBudgetTab(app: app)
        tapButton(app.buttons["workspaceAddMenu"])
        tapButton(app.buttons["workspaceAddCategoryButton"])

        let titleInput = app.textFields["categoryTitleTextField"]
        XCTAssertTrue(titleInput.waitForExistence(timeout: 5))
        replaceText(in: titleInput, with: title)

        let plannedInput = app.textFields["categoryPlannedTextField"]
        XCTAssertTrue(plannedInput.waitForExistence(timeout: 5))
        replaceText(in: plannedInput, with: plannedAmount)

        tapButton(app.buttons["categorySaveButton"])
        assertCategoryExists(app: app, title: title)
    }

    private func openCategoryEditor(app: XCUIApplication, title: String) {
        openBudgetTab(app: app)
        let categoryRow = app.buttons["categoryRow_\(title)"]
        XCTAssertTrue(categoryRow.waitForExistence(timeout: 5))
        categoryRow.tap()
        XCTAssertTrue(app.navigationBars["Edit Category"].waitForExistence(timeout: 5))
    }

    private func createTransaction(
        app: XCUIApplication,
        categoryTitle: String,
        transactionTitle: String,
        amount: String
    ) {
        openTransactionsTab(app: app)
        tapButton(app.buttons["newTransactionButton"])

        let categoryPicker = app.buttons["transactionCategoryPicker"]
        XCTAssertTrue(categoryPicker.waitForExistence(timeout: 5))
        categoryPicker.tap()
        tapButton(app.buttons[categoryTitle])

        let titleInput = app.textFields["transactionTitleTextField"]
        XCTAssertTrue(titleInput.waitForExistence(timeout: 5))
        replaceText(in: titleInput, with: transactionTitle)

        let amountInput = app.textFields["transactionAmountTextField"]
        XCTAssertTrue(amountInput.waitForExistence(timeout: 5))
        replaceText(in: amountInput, with: amount)

        tapButton(app.buttons["transactionSaveButton"])
        XCTAssertTrue(app.buttons["transactionRow_\(transactionTitle)"].waitForExistence(timeout: 5))
    }

    private func openBudgetTab(app: XCUIApplication) {
        tapButton(app.tabBars.buttons["Budget"])
    }

    private func openTransactionsTab(app: XCUIApplication) {
        tapButton(app.tabBars.buttons["Transactions"])
    }

    private func assertCategoryExists(app: XCUIApplication, title: String) {
        XCTAssertTrue(app.buttons["categoryRow_\(title)"].waitForExistence(timeout: 5))
    }

    private func assertCategoryAmount(app: XCUIApplication, title: String, amount: String) {
        assertCategoryExists(app: app, title: title)
        assertStaticTextValue(app.staticTexts["categoryAmount_\(title)"], equals: amount)
    }

    private func assertStaticTextValue(_ element: XCUIElement, equals expectedValue: String) {
        XCTAssertTrue(element.waitForExistence(timeout: 5))
        XCTAssertEqual(element.label, expectedValue)
    }

    private func replaceText(in textField: XCUIElement, with text: String) {
        textField.tap()
        textField.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 40))
        textField.typeText(text)
    }

    private func tapButton(_ button: XCUIElement) {
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        button.tap()
    }
}
