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
}
