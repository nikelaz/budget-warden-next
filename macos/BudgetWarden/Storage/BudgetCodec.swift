import Foundation

enum BudgetCodec {
    static func makeJSON(from draft: BudgetDraft) throws -> Swift.String {
        var budget = Budget()

        guard budget_init(&budget, draft.title, draft.periodStart, draft.periodEnd) == 0 else {
            throw BudgetVaultError.budgetCreationFailed
        }

        defer {
            budget_free(&budget)
        }

        var jsonString = budget_to_json_str(&budget)

        defer {
            bw_string_free(&jsonString)
        }

        guard let jsonData = jsonString.data else {
            throw BudgetVaultError.jsonCreationFailed
        }

        return Swift.String(cString: jsonData)
    }

    static func readBudget(from url: URL) throws -> BudgetDocument {
        var budget = try readCoreBudget(from: url)

        defer {
            budget_free(&budget)
        }

        let title = budget.title.data.map { Swift.String(cString: $0) } ?? url.deletingPathExtension().lastPathComponent

        return BudgetDocument(
            id: url,
            url: url,
            title: title,
            periodStart: budget.period_start,
            periodEnd: budget.period_end,
            categories: categories(from: budget)
        )
    }

    static func addCategory(_ draft: CategoryDraft, to url: URL) throws -> BudgetDocument {
        var budget = try readCoreBudget(from: url)

        defer {
            budget_free(&budget)
        }

        var category = Category()

        guard category_init(&category, draft.title, 0, 0, 0, draft.type.coreType) == 0 else {
            throw BudgetVaultError.categoryCreationFailed
        }

        category.id = nextCategoryID(in: budget)

        guard category_array_push_move(&budget.categories, category) == 0 else {
            category_free(&category)
            throw BudgetVaultError.categorySaveFailed
        }

        var jsonString = budget_to_json_str(&budget)

        defer {
            bw_string_free(&jsonString)
        }

        guard let jsonData = jsonString.data else {
            throw BudgetVaultError.jsonCreationFailed
        }

        try Swift.String(cString: jsonData).write(to: url, atomically: true, encoding: .utf8)
        return try readBudget(from: url)
    }

    private static func readCoreBudget(from url: URL) throws -> Budget {
        let json: Swift.String

        do {
            json = try Swift.String(contentsOf: url, encoding: .utf8)
        } catch {
            throw BudgetVaultError.budgetReadFailed(url)
        }

        var budget = Budget()
        let result = json.withCString { budget_from_json_str(&budget, $0) }

        guard result == 0 else {
            throw BudgetVaultError.budgetReadFailed(url)
        }

        return budget
    }

    private static func categories(from budget: Budget) -> [BudgetCategory] {
        guard let items = budget.categories.items else {
            return []
        }

        return (0..<budget.categories.length).compactMap { index in
            let category = items[index]

            guard let type = BudgetCategoryType(coreType: category.category_type) else {
                return nil
            }

            let title = category.title.data.map { Swift.String(cString: $0) } ?? ""

            return BudgetCategory(
                id: "\(type.id)-\(category.id)-\(index)",
                coreID: Int(category.id),
                title: title,
                amountPlanned: category.amount_planned,
                amountActual: category.amount_actual,
                amountAccumulated: category.amount_accumulated,
                type: type
            )
        }
    }

    private static func nextCategoryID(in budget: Budget) -> Int32 {
        guard let items = budget.categories.items else {
            return 1
        }

        let maxID = (0..<budget.categories.length).map { items[$0].id }.max() ?? 0
        return maxID + 1
    }
}
