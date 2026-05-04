import Foundation

final class CoreBudgetHandle {
    var budget = Budget()

    init(title: Swift.String) throws {
        guard budget_init(&budget, title) == 0 else {
            throw BudgetVaultError.budgetCreationFailed
        }
    }

    init(json: Swift.String, url: URL) throws {
        let result = json.withCString { budget_from_json_str(&budget, $0) }

        guard result == 0 else {
            throw BudgetVaultError.budgetReadFailed(url)
        }
    }

    deinit {
        budget_free(&budget)
    }

    func withUnsafeMutableBudget<T>(_ body: (inout Budget) throws -> T) rethrows -> T {
        try body(&budget)
    }

    func document(url: URL) throws -> BudgetDocument {
        try CoreBudgetMapper.document(from: budget, url: url)
    }

    func jsonString() throws -> Swift.String {
        var jsonString = budget_to_json_str(&budget)

        defer {
            bw_string_free(&jsonString)
        }

        guard let jsonData = jsonString.data else {
            throw BudgetVaultError.jsonCreationFailed
        }

        return Swift.String(cString: jsonData)
    }
}
