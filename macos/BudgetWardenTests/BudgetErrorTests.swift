import XCTest
@testable import BudgetWarden

final class BudgetErrorTests: XCTestCase {
    func testURLBasedErrorDescriptionsIncludeFileName() {
        let url = URL(fileURLWithPath: "/tmp/Family.budget")

        XCTAssertEqual(
            BudgetError.budgetReadFailed(url).errorDescription,
            "The budget file could not be read: Family.budget"
        )
        XCTAssertEqual(
            BudgetError.budgetRemoveFailed(url).errorDescription,
            "The budget file could not be moved to Trash: Family.budget"
        )
    }
}
