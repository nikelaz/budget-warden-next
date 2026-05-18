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

    func testCreateNewBudgetFromWelcome() throws {
        // @TODO(Niki): Generate a unique name for the test budget
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
        titleInput.typeText("Test Budget")

        let saveButton = app.buttons["Save"]
        XCTAssertTrue(saveButton.waitForExistence(timeout: 5))
        saveButton.click()
        
        // @TOOD(Niki): Check if main window opened with the new user experience fields here
        
        app.terminate()
        app.launch()

        // @TODO(Niki): This title is probably not in staticTexts, that's why it's not found, has to be fixed
        let testBudgetTitle = app.staticTexts["Test Budget"]
        XCTAssertTrue(testBudgetTitle.waitForExistence(timeout: 5))
        
        // @TODO(Niki): The budget should be removed here
        
        app.terminate()
    }
}
