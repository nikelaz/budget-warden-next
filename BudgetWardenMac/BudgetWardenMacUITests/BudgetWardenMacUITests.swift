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

final class BudgetWardenMacUITests: XCTestCase {
    func testWelcomeWindowUI() {
        let app = XCUIApplication()
        app.launch()

        openWelcomeWindow(app)

        let appTitle = app.staticTexts["Budget Warden"]
        XCTAssertTrue(appTitle.waitForExistence(timeout: 5))
        
        let createBudgetBtn = app.buttons["Create New Budget"]
        XCTAssertTrue(createBudgetBtn.waitForExistence(timeout: 5))
        
        let openBudgetBtn = app.buttons["Open Budget"]
        XCTAssertTrue(openBudgetBtn.waitForExistence(timeout: 5))
        
        let recentlyOpenedTitle = app.staticTexts["Recently Opened"]
        XCTAssertTrue(recentlyOpenedTitle.waitForExistence(timeout: 5))

        app.terminate()
    }

    func testCreateNewBudgetFromWelcome() {
        let budgetName = "Test Budget \(UUID().uuidString)"

        let app = XCUIApplication()
        app.launch()

        openWelcomeWindow(app)

        let createBudgetBtn = app.buttons["Create New Budget"]
        XCTAssertTrue(createBudgetBtn.waitForExistence(timeout: 5))
        createBudgetBtn.click()

        let newBudgetLabel = app.staticTexts["New Budget"]
        XCTAssertTrue(newBudgetLabel.waitForExistence(timeout: 5))

        let titleInput = app.textFields["titleTextField"]
        XCTAssertTrue(titleInput.waitForExistence(timeout: 5))

        /* @TODO(Niki): Template input needs to be selected with an accessibility identifier
         and a different function
        let templateInput = app.popUpButtons["Template"]
        XCTAssertTrue(templateInput.waitForExistence(timeout: 5))
         */

        titleInput.click()
        titleInput.typeKey("a", modifierFlags: [.command])
        titleInput.typeText(budgetName)

        let saveButton = app.buttons["Save"]
        XCTAssertTrue(saveButton.waitForExistence(timeout: 5))
        saveButton.click()
         
        let salaryLabel = app.staticTexts["Salary"]
        XCTAssertTrue(salaryLabel.waitForExistence(timeout: 5))

        let funAndEntertainmentLabel = app.staticTexts["Fun & Entertainment"]
        XCTAssertTrue(funAndEntertainmentLabel.waitForExistence(timeout: 5))

        let healthAndFitnessLabel = app.staticTexts["Health & Fitness"]
        XCTAssertTrue(healthAndFitnessLabel.waitForExistence(timeout: 5))

        let givingLabel = app.staticTexts["Giving"]
        XCTAssertTrue(givingLabel.waitForExistence(timeout: 5))

        let utilitiesLabel = app.staticTexts["Utilities"]
        XCTAssertTrue(utilitiesLabel.waitForExistence(timeout: 5))

        let miscLabel = app.staticTexts["Miscellaneous"]
        XCTAssertTrue(miscLabel.waitForExistence(timeout: 5))

        let insuranceLabel = app.staticTexts["Insurance"]
        XCTAssertTrue(insuranceLabel.waitForExistence(timeout: 5))

        let housingLabel = app.staticTexts["Housing"]
        XCTAssertTrue(housingLabel.waitForExistence(timeout: 5))

        let foodLabel = app.staticTexts["Food"]
        XCTAssertTrue(foodLabel.waitForExistence(timeout: 5))

        let personalCareLabel = app.staticTexts["Personal Care"]
        XCTAssertTrue(personalCareLabel.waitForExistence(timeout: 5))

        let transportationLabel = app.staticTexts["Transportation"]
        XCTAssertTrue(transportationLabel.waitForExistence(timeout: 5))

        let emergencyFundLabel = app.staticTexts["Emergency Fund"]
        XCTAssertTrue(emergencyFundLabel.waitForExistence(timeout: 5))

        let retirementLabel = app.staticTexts["Retirement"]
        XCTAssertTrue(retirementLabel.waitForExistence(timeout: 5))

        app.terminate()
        app.launch()
        openWelcomeWindow(app)

        let testBudgetButton = app.buttons["Button_\(budgetName)"]
        XCTAssertTrue(testBudgetButton.waitForExistence(timeout: 5))
        
        testBudgetButton.rightClick()

        let removeMenuItem = app.menuItems["Remove from Recents"]
        XCTAssertTrue(removeMenuItem.waitForExistence(timeout: 2))

        removeMenuItem.click()

        let testBudgetButtonAfterDelete = app.buttons["Button_\(budgetName)"]
        XCTAssertFalse(testBudgetButtonAfterDelete.waitForExistence(timeout: 5))

        app.terminate()
    }

    func testCategoryCreateDelete() {
        let suffix = String(UUID().uuidString.prefix(8))
        let budgetName = "Test Budget \(suffix)"
        let incomeTitle = "Income Footer \(suffix)"
        let expenseTitle = "Expense Footer \(suffix)"
        let savingsTitle = "Savings Footer \(suffix)"
        let debtTitle = "Debt Footer \(suffix)"
        let toolbarIncomeTitle = "Income Toolbar \(suffix)"
        let toolbarExpenseTitle = "Expense Toolbar \(suffix)"
        let toolbarSavingsTitle = "Savings Toolbar \(suffix)"
        let toolbarDebtTitle = "Debt Toolbar \(suffix)"
        let transactionTitle = "Income Transaction \(suffix)"

        let app = XCUIApplication()
        app.launch()

        openWelcomeWindow(app)

        createBudgetFromWelcome(app: app, budgetName: budgetName)
        createTransaction(
            app: app,
            categoryTitle: "Salary",
            transactionTitle: transactionTitle,
            amount: "123.45"
        )

        openBudgetSidebar(app: app)

        createCategoryFromFooter(
            app: app,
            typeTitle: "Income",
            title: incomeTitle,
            plannedAmount: "111.11"
        )
        assertCategoryPlannedAndActual(app: app, title: incomeTitle, planned: "111.11", actual: "0.00")

        createCategoryFromFooter(
            app: app,
            typeTitle: "Expenses",
            title: expenseTitle,
            plannedAmount: "222.22"
        )
        assertCategoryPlannedAndActual(app: app, title: expenseTitle, planned: "222.22", actual: "0.00")

        createCategoryFromFooter(
            app: app,
            typeTitle: "Savings",
            title: savingsTitle,
            plannedAmount: "333.33"
        )
        assertCategoryTableValues(
            app: app,
            title: savingsTitle,
            accumulated: "0.00",
            planned: "333.33",
            actual: "0.00"
        )

        createCategoryFromFooter(
            app: app,
            typeTitle: "Debt",
            title: debtTitle,
            plannedAmount: "444.44"
        )
        assertCategoryTableValues(
            app: app,
            title: debtTitle,
            accumulated: "0.00",
            planned: "444.44",
            actual: "0.00"
        )

        createCategoryFromToolbar(
            app: app,
            typeTitle: "Income",
            title: toolbarIncomeTitle,
            plannedAmount: "555.55"
        )
        assertCategoryPlannedAndActual(app: app, title: toolbarIncomeTitle, planned: "555.55", actual: "0.00")

        createCategoryFromToolbar(
            app: app,
            typeTitle: "Expenses",
            title: toolbarExpenseTitle,
            plannedAmount: "666.66"
        )
        assertCategoryPlannedAndActual(app: app, title: toolbarExpenseTitle, planned: "666.66", actual: "0.00")

        createCategoryFromToolbar(
            app: app,
            typeTitle: "Savings",
            title: toolbarSavingsTitle,
            plannedAmount: "777.77"
        )
        assertCategoryTableValues(
            app: app,
            title: toolbarSavingsTitle,
            accumulated: "0.00",
            planned: "777.77",
            actual: "0.00"
        )

        createCategoryFromToolbar(
            app: app,
            typeTitle: "Debt",
            title: toolbarDebtTitle,
            plannedAmount: "888.88"
        )
        assertCategoryTableValues(
            app: app,
            title: toolbarDebtTitle,
            accumulated: "0.00",
            planned: "888.88",
            actual: "0.00"
        )

        deleteCategoryFromInspector(app: app, title: toolbarExpenseTitle)
        assertCategoryDoesNotExist(app: app, title: toolbarExpenseTitle)

        deleteCategoryFromContextMenu(app: app, title: toolbarDebtTitle)
        assertCategoryDoesNotExist(app: app, title: toolbarDebtTitle)

        app.terminate()
        app.launch()

        openWelcomeWindow(app)

        openBudgetFromWelcome(app: app, budgetName: budgetName)

        app.terminate()
        app.launch()

        openWelcomeWindow(app)

        removeBudgetFromWelcome(app: app, budgetName: budgetName)

        app.terminate()
    }

    func testBudgetSwitch() {
        let suffix = String(UUID().uuidString.prefix(8))
        let firstBudgetName = "Test Budget One \(suffix)"
        let secondBudgetName = "Test Budget Two \(suffix)"
        let firstBudgetCategoryTitle = "First Budget Marker \(suffix)"
        let secondBudgetCategoryTitle = "Second Budget Marker \(suffix)"

        let app = XCUIApplication()
        app.launch()

        openWelcomeWindow(app)

        createBudgetFromWelcome(app: app, budgetName: firstBudgetName)
        openBudgetSidebar(app: app)
        createCategoryFromFooter(
            app: app,
            typeTitle: "Expenses",
            title: firstBudgetCategoryTitle,
            plannedAmount: "101.01"
        )
        assertCategoryPlannedAndActual(app: app, title: firstBudgetCategoryTitle, planned: "101.01", actual: "0.00")

        app.terminate()
        app.launch()

        openWelcomeWindow(app)

        createBudgetFromWelcome(app: app, budgetName: secondBudgetName)
        openBudgetSidebar(app: app)
        createCategoryFromFooter(
            app: app,
            typeTitle: "Expenses",
            title: secondBudgetCategoryTitle,
            plannedAmount: "202.02"
        )
        assertCategoryPlannedAndActual(app: app, title: secondBudgetCategoryTitle, planned: "202.02", actual: "0.00")

        openBudgetSwitcher(app: app)
        XCTAssertTrue(app.menuItems[firstBudgetName].waitForExistence(timeout: 5))
        XCTAssertTrue(app.menuItems[secondBudgetName].waitForExistence(timeout: 5))
        app.menuItems[firstBudgetName].click()

        assertCategoryPlannedAndActual(app: app, title: firstBudgetCategoryTitle, planned: "101.01", actual: "0.00")
        XCTAssertFalse(app.staticTexts["budgetCategoryTitle_\(secondBudgetCategoryTitle)"].waitForExistence(timeout: 2))

        app.terminate()
        app.launch()

        openWelcomeWindow(app)

        removeBudgetFromWelcome(app: app, budgetName: firstBudgetName)
        removeBudgetFromWelcome(app: app, budgetName: secondBudgetName)

        app.terminate()
    }

    func testBudgetCategoryInspectorEditsPersist() {
        let suffix = String(UUID().uuidString.prefix(8))
        let budgetName = "Test Budget \(suffix)"
        let updatedCategoryTitle = "Emergency Fund Updated \(suffix)"
        let accumulatedAmount = "789.01"
        let plannedAmount = "1234.56"
        let actualAmount = "45.67"

        let app = XCUIApplication()
        app.launch()

        openWelcomeWindow(app)

        createBudgetFromWelcome(app: app, budgetName: budgetName)
        createTransaction(
            app: app,
            categoryTitle: "Emergency Fund",
            transactionTitle: "Emergency Fund Actual \(suffix)",
            amount: actualAmount
        )

        openBudgetSidebar(app: app)
        selectCategory(app: app, title: "Emergency Fund")

        replaceText(in: app.textFields["categoryInspectorTitleTextField"], with: updatedCategoryTitle)
        replaceText(in: app.textFields["categoryInspectorAccumulatedTextField"], with: accumulatedAmount)
        replaceText(in: app.textFields["categoryInspectorPlannedTextField"], with: plannedAmount)
        app.typeKey(.return, modifierFlags: [])

        assertCategoryTableValues(
            app: app,
            title: updatedCategoryTitle,
            accumulated: accumulatedAmount,
            planned: plannedAmount,
            actual: actualAmount
        )

        app.terminate()
        app.launch()

        openWelcomeWindow(app)

        openBudgetFromWelcome(app: app, budgetName: budgetName)

        assertCategoryTableValues(
            app: app,
            title: updatedCategoryTitle,
            accumulated: accumulatedAmount,
            planned: plannedAmount,
            actual: actualAmount
        )

        app.terminate()
        app.launch()

        openWelcomeWindow(app)

        removeBudgetFromWelcome(app: app, budgetName: budgetName)

        app.terminate()
    }

    private func createBudgetFromWelcome(app: XCUIApplication, budgetName: String) {
        let createBudgetBtn = app.buttons["Create New Budget"]
        XCTAssertTrue(createBudgetBtn.waitForExistence(timeout: 5))
        createBudgetBtn.click()

        let titleInput = app.textFields["titleTextField"]
        XCTAssertTrue(titleInput.waitForExistence(timeout: 5))
        replaceText(in: titleInput, with: budgetName)

        let saveButton = app.buttons["Save"]
        XCTAssertTrue(saveButton.waitForExistence(timeout: 5))
        saveButton.click()

        XCTAssertTrue(app.staticTexts["Emergency Fund"].waitForExistence(timeout: 5))
    }

    private func createTransaction(
        app: XCUIApplication,
        categoryTitle: String,
        transactionTitle: String,
        amount: String
    ) {
        openTransactionsSidebar(app: app)

        let addTransactionButton = app.buttons["Add Transaction"]
        XCTAssertTrue(addTransactionButton.waitForExistence(timeout: 5))
        addTransactionButton.click()

        let categoryPicker = app.descendants(matching: .any)["transactionCategoryPicker"]
        XCTAssertTrue(categoryPicker.waitForExistence(timeout: 5))
        categoryPicker.click()

        let categoryMenuItem = app.menuItems[categoryTitle]
        XCTAssertTrue(categoryMenuItem.waitForExistence(timeout: 5))
        categoryMenuItem.click()

        let titleInput = app.textFields["transactionTitleTextField"]
        XCTAssertTrue(titleInput.waitForExistence(timeout: 5))
        replaceText(in: titleInput, with: transactionTitle)

        let amountInput = app.textFields["transactionAmountTextField"]
        XCTAssertTrue(amountInput.waitForExistence(timeout: 5))
        replaceText(in: amountInput, with: amount)

        let saveButton = app.buttons["transactionSaveButton"]
        XCTAssertTrue(saveButton.waitForExistence(timeout: 5))
        saveButton.click()

        XCTAssertTrue(app.staticTexts[transactionTitle].waitForExistence(timeout: 5))
    }

    private func createCategoryFromFooter(
        app: XCUIApplication,
        typeTitle: String,
        title: String,
        plannedAmount: String
    ) {
        let createButton = app.descendants(matching: .any)["create\(typeTitle)CategoryFooterButton"]
        XCTAssertTrue(createButton.waitForExistence(timeout: 5))
        createButton.click()

        createCategoryFromOpenSheet(app: app, title: title, plannedAmount: plannedAmount)
    }

    private func createCategoryFromToolbar(
        app: XCUIApplication,
        typeTitle: String,
        title: String,
        plannedAmount: String
    ) {
        let addMenu = app.descendants(matching: .any)["addToolbarMenu"]
        XCTAssertTrue(addMenu.waitForExistence(timeout: 5))
        addMenu.click()

        let categoryMenuItem = app.menuItems["Category"]
        if categoryMenuItem.waitForExistence(timeout: 2) {
            categoryMenuItem.click()
        }
        else {
            let categoryButton = app.buttons["Category"]
            XCTAssertTrue(categoryButton.waitForExistence(timeout: 5))
            categoryButton.click()
        }

        let typePicker = app.descendants(matching: .any)["createCategoryTypePicker"]
        XCTAssertTrue(typePicker.waitForExistence(timeout: 5))
        typePicker.click()

        let typeMenuItem = app.menuItems[typeTitle]
        XCTAssertTrue(typeMenuItem.waitForExistence(timeout: 5))
        typeMenuItem.click()

        createCategoryFromOpenSheet(app: app, title: title, plannedAmount: plannedAmount)
    }

    private func createCategoryFromOpenSheet(
        app: XCUIApplication,
        title: String,
        plannedAmount: String
    ) {
        let titleInput = app.textFields["createCategoryTitleTextField"]
        XCTAssertTrue(titleInput.waitForExistence(timeout: 5))
        replaceText(in: titleInput, with: title)

        let plannedAmountInput = app.textFields["createCategoryPlannedAmountTextField"]
        XCTAssertTrue(plannedAmountInput.waitForExistence(timeout: 5))
        replaceText(in: plannedAmountInput, with: plannedAmount)

        let saveButton = app.buttons["Save"]
        XCTAssertTrue(saveButton.waitForExistence(timeout: 5))
        saveButton.click()

        assertCategoryExists(app: app, title: title)
    }

    private func deleteCategoryFromInspector(app: XCUIApplication, title: String) {
        selectCategory(app: app, title: title)

        let deleteButton = app.buttons["categoryInspectorDeleteButton"]
        XCTAssertTrue(deleteButton.waitForExistence(timeout: 5))
        deleteButton.click()

        let confirmButton = app.buttons["categoryInspectorDeleteConfirmButton"]
        XCTAssertTrue(confirmButton.waitForExistence(timeout: 5))
        confirmButton.click()
    }

    private func deleteCategoryFromContextMenu(app: XCUIApplication, title: String) {
        let titleCell = app.staticTexts["budgetCategoryTitle_\(title)"]
        XCTAssertTrue(titleCell.waitForExistence(timeout: 5))
        titleCell.rightClick()

        let deleteMenuItem = app.menuItems["categoryContextMenuDeleteButton"]
        if deleteMenuItem.waitForExistence(timeout: 2) {
            deleteMenuItem.click()
        }
        else {
            let deleteMenuItemByLabel = app.menuItems["Delete Category"]
            XCTAssertTrue(deleteMenuItemByLabel.waitForExistence(timeout: 5))
            deleteMenuItemByLabel.click()
        }

        let confirmButton = app.buttons["categoryTableDeleteConfirmButton"]
        XCTAssertTrue(confirmButton.waitForExistence(timeout: 5))
        confirmButton.click()
    }

    private func openBudgetSwitcher(app: XCUIApplication) {
        let budgetSwitcher = app.descendants(matching: .any)["budgetSwitcherMenu"]
        XCTAssertTrue(budgetSwitcher.waitForExistence(timeout: 5))
        budgetSwitcher.click()
    }

    private func openBudgetFromWelcome(app: XCUIApplication, budgetName: String) {
        let budgetButton = app.buttons["Button_\(budgetName)"]
        XCTAssertTrue(budgetButton.waitForExistence(timeout: 5))
        budgetButton.click()

        XCTAssertTrue(app.staticTexts["Budget"].waitForExistence(timeout: 5))
    }

    private func removeBudgetFromWelcome(app: XCUIApplication, budgetName: String) {
        let budgetButton = app.buttons["Button_\(budgetName)"]
        XCTAssertTrue(budgetButton.waitForExistence(timeout: 5))
        budgetButton.rightClick()

        let removeMenuItem = app.menuItems["Remove from Recents"]
        XCTAssertTrue(removeMenuItem.waitForExistence(timeout: 2))
        removeMenuItem.click()

        XCTAssertFalse(budgetButton.waitForExistence(timeout: 5))
    }

    private func openBudgetSidebar(app: XCUIApplication) {
        let budgetSidebarButton = app.descendants(matching: .any)["sidebarBudgetButton"]
        XCTAssertTrue(budgetSidebarButton.waitForExistence(timeout: 5))
        budgetSidebarButton.click()
    }

    private func openTransactionsSidebar(app: XCUIApplication) {
        let transactionsSidebarButton = app.descendants(matching: .any)["sidebarTransactionsButton"]
        XCTAssertTrue(transactionsSidebarButton.waitForExistence(timeout: 5))
        transactionsSidebarButton.click()
    }

    private func selectCategory(app: XCUIApplication, title: String) {
        let categoryTitle = app.staticTexts[title]
        XCTAssertTrue(categoryTitle.waitForExistence(timeout: 5))
        categoryTitle.click()
    }

    private func replaceText(in textField: XCUIElement, with text: String) {
        XCTAssertTrue(textField.waitForExistence(timeout: 5))
        textField.click()
        textField.typeKey("a", modifierFlags: [.command])
        textField.typeText(text)
    }

    private func assertCategoryTableValues(
        app: XCUIApplication,
        title: String,
        accumulated: String,
        planned: String,
        actual: String
    ) {
        assertCategoryExists(app: app, title: title)

        assertStaticTextValue(
            app.staticTexts["budgetCategoryAccumulated_\(title)"],
            equals: accumulated
        )
        assertStaticTextValue(
            app.staticTexts["budgetCategoryPlanned_\(title)"],
            equals: planned
        )
        assertStaticTextValue(
            app.staticTexts["budgetCategoryActual_\(title)"],
            equals: actual
        )
    }

    private func assertCategoryPlannedAndActual(
        app: XCUIApplication,
        title: String,
        planned: String,
        actual: String
    ) {
        assertCategoryExists(app: app, title: title)
        assertStaticTextValue(
            app.staticTexts["budgetCategoryPlanned_\(title)"],
            equals: planned
        )
        assertStaticTextValue(
            app.staticTexts["budgetCategoryActual_\(title)"],
            equals: actual
        )
    }

    private func assertCategoryExists(app: XCUIApplication, title: String) {
        let titleCell = app.staticTexts["budgetCategoryTitle_\(title)"]
        XCTAssertTrue(titleCell.waitForExistence(timeout: 5))
    }

    private func assertCategoryDoesNotExist(app: XCUIApplication, title: String) {
        let titleCell = app.staticTexts["budgetCategoryTitle_\(title)"]
        XCTAssertFalse(titleCell.waitForExistence(timeout: 5))
    }

    private func assertStaticTextValue(_ element: XCUIElement, equals expectedValue: String) {
        XCTAssertTrue(element.waitForExistence(timeout: 5))
        XCTAssertEqual(element.value as? String, expectedValue)
    }

    private func openWelcomeWindow(_ app: XCUIApplication) {
        let windowMenu = app.menuBars.menuBarItems["Window"]

        if windowMenu.exists {
            windowMenu.click()

            let welcomeWindow = app.menuItems["Welcome Window"]
            if welcomeWindow.exists {
                welcomeWindow.click()
            }
        }
    }
}
