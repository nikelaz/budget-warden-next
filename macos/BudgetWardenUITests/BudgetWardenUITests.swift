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

final class BudgetWardenUITests: XCTestCase {
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
        
        let configureVaultBtn = app.buttons["Configure Vault"]
        XCTAssertTrue(configureVaultBtn.waitForExistence(timeout: 5))
        
        let budgetsInVaultTitle = app.staticTexts["Budgets in Vault"]
        XCTAssertTrue(budgetsInVaultTitle.waitForExistence(timeout: 5))

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

        let removeMenuItem = app.menuItems["Remove from Vault"]
        XCTAssertTrue(removeMenuItem.waitForExistence(timeout: 2))

        removeMenuItem.click()

        let removeDialogHeading = app.staticTexts["Remove Budget?"]
        XCTAssertTrue(removeDialogHeading.waitForExistence(timeout: 2))

        let confirmDeleteButton = app.buttons["MoveToTrashRemoveBudgetConfirm"]
        XCTAssertTrue(confirmDeleteButton.waitForExistence(timeout: 5))

        confirmDeleteButton.click()

        let testBudgetButtonAfterDelete = app.buttons["Button_\(budgetName)"]
        XCTAssertFalse(testBudgetButtonAfterDelete.waitForExistence(timeout: 5))

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

        let removeMenuItem = app.menuItems["Remove from Vault"]
        XCTAssertTrue(removeMenuItem.waitForExistence(timeout: 2))
        removeMenuItem.click()

        let confirmDeleteButton = app.buttons["MoveToTrashRemoveBudgetConfirm"]
        XCTAssertTrue(confirmDeleteButton.waitForExistence(timeout: 5))
        confirmDeleteButton.click()

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
        let titleCell = app.staticTexts["budgetCategoryTitle_\(title)"]
        XCTAssertTrue(titleCell.waitForExistence(timeout: 5))

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
