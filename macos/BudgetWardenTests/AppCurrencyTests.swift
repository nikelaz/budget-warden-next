import XCTest
@testable import BudgetWarden

final class AppCurrencyTests: XCTestCase {
    func testSupportedCurrenciesHaveDisplayNames() {
        XCTAssertEqual(AppCurrency.allCases.map(\.rawValue), ["EUR", "USD", "GBP", "BGN", "CHF", "JPY"])

        for currency in AppCurrency.allCases {
            XCTAssertFalse(currency.title.isEmpty)
            XCTAssertFalse(currency.symbol.isEmpty)
            XCTAssertTrue(currency.displayName.contains(currency.title))
            XCTAssertTrue(currency.displayName.contains(currency.symbol))
        }
    }
}
