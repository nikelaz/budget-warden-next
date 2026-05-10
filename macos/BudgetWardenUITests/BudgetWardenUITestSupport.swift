import XCTest

class BudgetWardenUITestCase: XCTestCase {
    var app: XCUIApplication!
    private var trackedBudgetNames: [String] = []

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = launchApp()
    }

    override func tearDownWithError() throws {
        cleanupTrackedBudgets()
        app?.terminate()
        app = nil
        trackedBudgetNames = []
    }

    func launchApp() -> XCUIApplication {
        let launchedApp = XCUIApplication()
        launchedApp.launchArguments = [
            "-ApplePersistenceIgnoreState", "YES",
            "-SelectedCurrency", "USD"
        ]
        launchedApp.launchEnvironment = [
            "AppleLanguages": "(en)",
            "AppleLocale": "en_US"
        ]
        launchedApp.launch()
        focusWelcomeWindow(in: launchedApp)
        return launchedApp
    }

    func focusWelcomeWindow(in launchedApp: XCUIApplication? = nil) {
        let targetApp = launchedApp ?? app!
        let welcomeButton = targetApp.buttons["welcome-create-budget-button"].exists
            ? targetApp.buttons["welcome-create-budget-button"]
            : targetApp.buttons["Create New Budget"]
        XCTAssertTrue(welcomeButton.waitForExistence(timeout: 5))

        let welcomeWindow = targetApp.windows
            .containing(.button, identifier: "welcome-create-budget-button")
            .firstMatch

        if welcomeWindow.exists {
            welcomeWindow.click()
        } else {
            welcomeButton.hover()
        }
    }

    @discardableResult
    func createTrackedBudget(named title: String) -> String {
        trackedBudgetNames.append(title)
        createBudget(named: title)
        return title
    }

    func createBudget(named title: String) {
        welcomeCreateBudgetButton.click()
        replaceText(in: app.textFields["budget-title-field"], with: title)
        app.buttons["Save"].click()
        XCTAssertTrue(app.staticTexts["Income"].waitForExistence(timeout: 5))
    }

    func relaunchToWelcome() {
        app.terminate()
        app = launchApp()
    }

    func openSidebarSection(_ section: SidebarSectionIdentifier) {
        let sidebarItem = app.descendants(matching: .any)["sidebar-\(section.rawValue)"].firstMatch
        XCTAssertTrue(sidebarItem.waitForExistence(timeout: 5))
        sidebarItem.click()
    }

    func addCategory(type: CategoryTypeIdentifier, title: String, plannedAmount: String) {
        let button = app.buttons["category-add-\(type.rawValue)-button"]
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        button.click()

        replaceText(in: app.textFields["new-category-title-field"], with: title)
        replaceText(in: app.textFields["new-category-planned-field"], with: plannedAmount)
        app.textFields["new-category-planned-field"].typeKey(.return, modifierFlags: [])

        XCTAssertTrue(categoryTitleCell(title).waitForExistence(timeout: 5))
    }

    func addTransactionFromToolbar(title: String, amount: String, description: String? = nil) {
        let button = app.buttons["transactions-add-transaction-button"].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        button.click()
        fillTransactionSheet(title: title, amount: amount, description: description)
    }

    func addTransactionFromCategoryActualCell(categoryTitle: String, title: String, amount: String) {
        let actualCell = app.descendants(matching: .any)["category-actual-cell-\(categoryTitle.accessibilityIdentifierComponent)"].firstMatch
        XCTAssertTrue(actualCell.waitForExistence(timeout: 5))
        actualCell.click()

        if !app.textFields["transaction-title-field"].waitForExistence(timeout: 1) {
            let toolbarButton = app.buttons["budget-add-transaction-button"].firstMatch
            XCTAssertTrue(toolbarButton.waitForExistence(timeout: 5))
            toolbarButton.click()
        }

        replaceText(in: app.textFields["transaction-title-field"], with: title)
        replaceText(in: app.textFields["transaction-amount-field"], with: amount)
        app.buttons["Save"].click()
    }

    func fillTransactionSheet(title: String, amount: String, description: String? = nil) {
        replaceText(in: app.textFields["transaction-title-field"], with: title)
        replaceText(in: app.textFields["transaction-amount-field"], with: amount)

        if let description {
            app.buttons["More Details"].firstMatch.click()
            replaceText(in: app.textFields["transaction-description-field"], with: description)
        }

        app.buttons["Save"].click()
        XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 5))
    }

    @discardableResult
    func editCategoryTitle(from oldTitle: String, to newTitle: String) -> Bool {
        let titleCell = categoryTitleCell(oldTitle)
        XCTAssertTrue(titleCell.waitForExistence(timeout: 5))
        titleCell.click()
        guard app.textFields["category-title-edit-field"].waitForExistence(timeout: 1) else {
            return false
        }
        replaceText(in: app.textFields["category-title-edit-field"], with: newTitle)
        app.textFields["category-title-edit-field"].typeKey(.return, modifierFlags: [])
        XCTAssertTrue(categoryTitleCell(newTitle).waitForExistence(timeout: 5))
        return true
    }

    func deleteCategory(named title: String) {
        let row = categoryRow(title)
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.rightClick()

        let deleteItem = app.menuItems["Delete Category"]
        XCTAssertTrue(deleteItem.waitForExistence(timeout: 5))
        deleteItem.click()

        let confirmButton = app.windows.sheets.buttons["Delete Category"].firstMatch
        XCTAssertTrue(confirmButton.waitForExistence(timeout: 5))
        confirmButton.click()

        XCTAssertTrue(row.waitForNonExistence(timeout: 5))
    }

    func deleteTransaction(named title: String) {
        let transactionText = app.staticTexts[title].firstMatch
        XCTAssertTrue(transactionText.waitForExistence(timeout: 5))
        transactionText.rightClick()

        let deleteItem = app.menuItems["Delete Transaction"].firstMatch
        XCTAssertTrue(deleteItem.waitForExistence(timeout: 5))
        deleteItem.click()

        let confirmButton = app.windows.sheets.buttons["Delete 1 Transaction"].firstMatch
        XCTAssertTrue(confirmButton.waitForExistence(timeout: 5))
        confirmButton.click()

        XCTAssertTrue(transactionText.waitForNonExistence(timeout: 5))
    }

    func replaceText(in element: XCUIElement, with text: String) {
        XCTAssertTrue(element.waitForExistence(timeout: 5))
        element.click()
        element.typeKey("a", modifierFlags: [.command])
        if text.isEmpty {
            element.typeKey(.delete, modifierFlags: [])
        } else {
            element.typeText(text)
        }
    }

    func categoryRow(_ title: String) -> XCUIElement {
        categoryTitleCell(title)
    }

    func categoryTitleCell(_ title: String) -> XCUIElement {
        app.descendants(matching: .any)["category-title-cell-\(title.accessibilityIdentifierComponent)"].firstMatch
    }

    func categoryValueCell(_ title: String, column: String) -> XCUIElement {
        app.descendants(matching: .any)["category-\(column)-cell-\(title.accessibilityIdentifierComponent)"].firstMatch
    }

    func removeTrackedBudgetFromWelcome(named title: String) {
        removeBudgetFromWelcome(named: title, assertExists: true)
        trackedBudgetNames.removeAll { $0 == title }
    }

    private func cleanupTrackedBudgets() {
        guard !trackedBudgetNames.isEmpty else {
            return
        }

        app?.terminate()
        app = launchApp()

        for title in trackedBudgetNames {
            removeBudgetFromWelcome(named: title, assertExists: false)
        }
    }

    private func removeBudgetFromWelcome(named title: String, assertExists: Bool) {
        let budgetRow = app.buttons["budget-row-\(title)"].firstMatch

        guard budgetRow.waitForExistence(timeout: assertExists ? 5 : 2) else {
            if assertExists {
                XCTFail("Budget row \(title) did not exist")
            }
            return
        }

        budgetRow.rightClick()

        let removeMenuItem = app.menuItems["Remove from Vault"]
        XCTAssertTrue(removeMenuItem.waitForExistence(timeout: 5))
        removeMenuItem.click()

        let confirmButton = app.windows.sheets.buttons["Move to Trash"].firstMatch
        XCTAssertTrue(confirmButton.waitForExistence(timeout: 5))
        confirmButton.click()

        XCTAssertTrue(budgetRow.waitForNonExistence(timeout: 5))
    }

    private var welcomeCreateBudgetButton: XCUIElement {
        let identifierButton = app.buttons["welcome-create-budget-button"]
        return identifierButton.exists ? identifierButton : app.buttons["Create New Budget"]
    }
}

enum SidebarSectionIdentifier: String {
    case budget
    case reporting
    case transactions
}

enum CategoryTypeIdentifier: String {
    case income
    case expenses
    case savings
    case debt
}

private extension String {
    var accessibilityIdentifierComponent: String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalars = unicodeScalars.map { scalar in
            allowed.contains(scalar) ? Character(scalar) : "-"
        }

        return String(scalars)
    }
}
