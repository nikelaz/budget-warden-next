import XCTest
@testable import BudgetWarden

final class AppCurrencyTests: XCTestCase {
    func testSupportedCurrenciesComeFromFoundation() {
        let foundationCurrencyCodes = Set(Locale.Currency.isoCurrencies.map(\.identifier))
        let appCurrencyCodes = Set(AppCurrency.allCases.map(\.rawValue))

        XCTAssertEqual(appCurrencyCodes, foundationCurrencyCodes)
        XCTAssertTrue(appCurrencyCodes.contains("EUR"))
        XCTAssertTrue(appCurrencyCodes.contains("USD"))
        XCTAssertTrue(appCurrencyCodes.contains("BGN"))
    }

    func testSupportedCurrenciesHaveDisplayNames() {
        for currency in AppCurrency.allCases.prefix(20) {
            XCTAssertFalse(currency.title.isEmpty)
            XCTAssertFalse(currency.symbol.isEmpty)
            XCTAssertTrue(currency.displayName.contains(currency.title))
            XCTAssertTrue(currency.displayName.contains(currency.rawValue))
        }
    }

    func testRawValueInitializesKnownCurrencyCodes() {
        XCTAssertEqual(AppCurrency(rawValue: "eur"), .eur)
        XCTAssertEqual(AppCurrency(rawValue: " USD ")?.rawValue, "USD")
    }

    func testRawValueRejectsUnknownCurrencyCodes() {
        XCTAssertNil(AppCurrency(rawValue: "not-a-currency"))
    }
}
