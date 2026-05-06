import Foundation

struct BudgetFileStore {
    func readText(from url: URL) throws -> Swift.String {
        do {
            return try Swift.String(contentsOf: url, encoding: .utf8)
        } catch {
            throw BudgetVaultError.budgetReadFailed(url)
        }
    }

    func writeText(_ text: Swift.String, to url: URL) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func remove(_ url: URL) throws {
        do {
            var trashedURL: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &trashedURL)
        } catch {
            throw BudgetVaultError.budgetRemoveFailed(url)
        }
    }
}
