import XCTest
@testable import BudgetWarden

final class MoneyAmountTests: XCTestCase {
    func testParseMoneyAmountScalesWholeAndFractionalValues() {
        XCTAssertEqual(UInt64.parseMoneyAmount("12"), 1_200)
        XCTAssertEqual(UInt64.parseMoneyAmount("12.3"), 1_230)
        XCTAssertEqual(UInt64.parseMoneyAmount("12.34"), 1_234)
        XCTAssertEqual(UInt64.parseMoneyAmount("0,99"), 99)
        XCTAssertEqual(UInt64.parseMoneyAmount(".50"), 50)
        XCTAssertEqual(UInt64.parseMoneyAmount(" 1234 "), 123_400)
    }

    func testParseMoneyAmountRejectsInvalidValues() {
        XCTAssertNil(UInt64.parseMoneyAmount("12.345"))
        XCTAssertNil(UInt64.parseMoneyAmount("12.3.4"))
        XCTAssertNil(UInt64.parseMoneyAmount("budget"))
        XCTAssertNil(UInt64.parseMoneyAmount("-1"))
        XCTAssertNil(UInt64.parseMoneyAmount("1 2"))
        XCTAssertNil(UInt64.parseMoneyAmount("1."))
    }

    func testParseMoneyAmountUsesEmptyValueForBlankInput() {
        XCTAssertEqual(UInt64.parseMoneyAmount("", emptyValue: 0), 0)
        XCTAssertEqual(UInt64.parseMoneyAmount(" \n ", emptyValue: 12_345), 12_345)
        XCTAssertNil(UInt64.parseMoneyAmount(""))
    }

    func testParseMoneyAmountRejectsOverflow() {
        XCTAssertNil(UInt64.parseMoneyAmount("184467440737095517"))
        XCTAssertNil(UInt64.parseMoneyAmount("184467440737095516.16"))
    }
}
