import XCTest
@testable import BudgetWarden

final class BudgetModelTests: XCTestCase {
    func testBudgetRowIdentityUsesURLNotCoreID() {
        let first = BudgetRow(
            url: URL(fileURLWithPath: "/tmp/First.budget"),
            coreID: 1,
            title: "First"
        )
        let second = BudgetRow(
            url: URL(fileURLWithPath: "/tmp/Second.budget"),
            coreID: 1,
            title: "Second"
        )

        XCTAssertEqual(first.coreID, second.coreID)
        XCTAssertNotEqual(first.id, second.id)
    }

    func testCategoryTypeMapsToAndFromCoreType() {
        for type in BudgetCategoryType.allCases {
            XCTAssertEqual(BudgetCategoryType(coreType: type.coreType), type)
        }
    }

    func testCoreDateFormattedDatePadsMonthAndDay() {
        let date = BWDate(year: 2026, month: 5, day: 7)

        XCTAssertEqual(date.formattedDate, "2026-05-07")
    }
}
