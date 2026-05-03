import XCTest
@testable import BudgetWarden

final class MoneyAmountTests: XCTestCase {
    func testParseMoneyAmountScalesWholeAndFractionalValues() {
        XCTAssertEqual(UInt64.parseMoneyAmount("12"), 1_200)
        XCTAssertEqual(UInt64.parseMoneyAmount("12.3"), 1_230)
        XCTAssertEqual(UInt64.parseMoneyAmount("12.34"), 1_234)
        XCTAssertEqual(UInt64.parseMoneyAmount("0,99"), 99)
        XCTAssertEqual(UInt64.parseMoneyAmount(".50"), 50)
    }

    func testParseMoneyAmountRejectsInvalidValues() {
        XCTAssertNil(UInt64.parseMoneyAmount("12.345"))
        XCTAssertNil(UInt64.parseMoneyAmount("12.3.4"))
        XCTAssertNil(UInt64.parseMoneyAmount("budget"))
        XCTAssertNil(UInt64.parseMoneyAmount("-1"))
    }

    func testMoneyAmountInputTextUsesTwoFractionDigits() {
        XCTAssertEqual(UInt64(0).moneyAmountInputText, "0.00")
        XCTAssertEqual(UInt64(1).moneyAmountInputText, "0.01")
        XCTAssertEqual(UInt64(1_234).moneyAmountInputText, "12.34")
    }
}
