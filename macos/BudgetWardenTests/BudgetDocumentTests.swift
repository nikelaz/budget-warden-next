import XCTest
@testable import BudgetWarden

final class BudgetDocumentTests: XCTestCase {
    func testIdentityUsesURLNotCoreID() {
        let first = BudgetDocument(
            coreID: 1,
            url: URL(fileURLWithPath: "/tmp/First.budget"),
            title: "First",
            categories: []
        )
        let second = BudgetDocument(
            coreID: 1,
            url: URL(fileURLWithPath: "/tmp/Second.budget"),
            title: "Second",
            categories: []
        )

        XCTAssertEqual(first.coreID, second.coreID)
        XCTAssertNotEqual(first.id, second.id)
    }
}
