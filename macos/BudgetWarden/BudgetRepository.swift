import Foundation

final class BudgetRepository {
    private let vault: BudgetVault
    private let fileManager = FileManager.default
    private static let jsonArenaCapacity = 1024 * 1024

    init(vault: BudgetVault = .shared) {
        self.vault = vault
    }

    func loadBudgets() throws -> [BudgetDocument] {
        let vaultURL = try vault.resolveVaultURL()

        return try vault.accessVault {
            try vault.budgetFileURLs(in: vaultURL)
                .compactMap { try? readBudget(at: $0) }
                .sorted(by: Self.sortByFileName)
        }
    }

    func createBudget(_ draft: BudgetDraft) throws -> BudgetDocument {
        let vaultURL = try vault.resolveVaultURL()

        return try vault.accessVault {
            let uniqueBudget = vault.uniqueBudgetLocation(for: draft.title, in: vaultURL)
            var coreBudget = BWBudget()

            if let templateURL = draft.templateURL {
                let result = templateURL.path.withCString {
                    bw_budget_init_from_template(&coreBudget, $0)
                }

                guard result == 0 else {
                    throw BudgetError.budgetCreationFailed
                }

                try replaceTitle(uniqueBudget.title, in: &coreBudget)
            } else {
                try initializeBudget(&coreBudget, title: uniqueBudget.title)
            }

            defer {
                bw_budget_free(&coreBudget)
            }

            coreBudget.id = Int32(try nextBudgetID(in: vaultURL))
            try writeText(jsonString(from: &coreBudget), to: uniqueBudget.url)
            return try document(from: coreBudget, url: uniqueBudget.url)
        }
    }

    func openBudget(at url: URL) throws -> BudgetDocument {
        try accessBudget(url) {
            try readBudget(at: url)
        }
    }

    func addCategory(_ draft: CategoryDraft, to budget: BudgetDocument) throws -> BudgetDocument {
        try mutateBudget(budget) { coreBudget in
            let result = draft.title.withCString { title in
                bw_budget_add_category_values(
                    &coreBudget,
                    title,
                    draft.amountPlanned,
                    0,
                    draft.amountAccumulated,
                    draft.type.coreType
                )
            }

            guard result == 0 else {
                throw BudgetError.categoryCreationFailed
            }
        }
    }

    func updateCategory(_ update: CategoryUpdate, in budget: BudgetDocument) throws -> BudgetDocument {
        try mutateBudget(budget) { coreBudget in
            let result = update.title.withCString { title in
                let coreUpdate = BWCategoryUpdate(
                    title: title,
                    amount_planned: update.amountPlanned,
                    amount_accumulated: update.amountAccumulated
                )

                return bw_budget_update_category(&coreBudget, Int32(update.categoryID), coreUpdate)
            }

            guard result == 0 else {
                throw BudgetError.categorySaveFailed
            }
        }
    }

    func removeCategory(_ category: BudgetCategory, from budget: BudgetDocument) throws -> BudgetDocument {
        try mutateBudget(budget) { coreBudget in
            guard bw_budget_remove_category(&coreBudget, Int32(category.coreID)) == 0 else {
                throw BudgetError.categoryNotFound
            }
        }
    }

    func reorderCategories(type: BudgetCategoryType, orderedCategoryIDs: [Int], in budget: BudgetDocument) throws -> BudgetDocument {
        try mutateBudget(budget) { coreBudget in
            let coreCategoryIDs = orderedCategoryIDs.map(Int32.init)
            let result = coreCategoryIDs.withUnsafeBufferPointer { buffer in
                bw_budget_reorder_categories(&coreBudget, type.coreType, buffer.baseAddress, buffer.count)
            }

            guard result == 0 else {
                throw BudgetError.categorySaveFailed
            }
        }
    }

    func addTransaction(_ draft: TransactionDraft, to budget: BudgetDocument) throws -> BudgetDocument {
        try mutateBudget(budget) { coreBudget in
            let result = draft.title.withCString { title in
                draft.description.withCString { description in
                    bw_budget_add_transaction_values(
                        &coreBudget,
                        Int32(draft.categoryID),
                        title,
                        description,
                        draft.date,
                        draft.amount
                    )
                }
            }

            guard result == 0 else {
                throw BudgetError.transactionCreationFailed
            }
        }
    }

    func updateTransaction(_ update: TransactionUpdate, in budget: BudgetDocument) throws -> BudgetDocument {
        try mutateBudget(budget) { coreBudget in
            let result = update.title.withCString { title in
                update.description.withCString { description in
                    let coreUpdate = BWTransactionUpdate(
                        category_id: Int32(update.categoryID),
                        title: title,
                        description: description,
                        date: update.date,
                        amount: update.amount
                    )

                    return bw_budget_update_transaction(&coreBudget, Int32(update.transactionID), coreUpdate)
                }
            }

            guard result == 0 else {
                throw BudgetError.transactionSaveFailed
            }
        }
    }

    func removeTransaction(_ transaction: BudgetTransaction, from budget: BudgetDocument) throws -> BudgetDocument {
        try mutateBudget(budget) { coreBudget in
            guard bw_budget_remove_transaction(&coreBudget, Int32(transaction.coreID)) == 0 else {
                throw BudgetError.transactionNotFound
            }
        }
    }

    func removeBudget(_ budget: BudgetDocument) throws {
        try accessBudget(budget.url) {
            try removeFile(at: budget.url)
        }
    }

    private func mutateBudget(
        _ budget: BudgetDocument,
        mutation: (inout BWBudget) throws -> Void
    ) throws -> BudgetDocument {
        try accessBudget(budget.url) {
            var coreBudget = BWBudget()
            try initializeBudget(&coreBudget, json: readText(from: budget.url), url: budget.url)
            defer {
                bw_budget_free(&coreBudget)
            }

            try mutation(&coreBudget)
            try writeText(jsonString(from: &coreBudget), to: budget.url)
            return try document(from: coreBudget, url: budget.url)
        }
    }

    private func readText(from url: URL) throws -> Swift.String {
        do {
            return try Swift.String(contentsOf: url, encoding: .utf8)
        } catch {
            throw BudgetError.budgetReadFailed(url)
        }
    }

    private func writeText(_ text: Swift.String, to url: URL) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func removeFile(at url: URL) throws {
        do {
            var trashedURL: NSURL?
            try fileManager.trashItem(at: url, resultingItemURL: &trashedURL)
        } catch {
            throw BudgetError.budgetRemoveFailed(url)
        }
    }

    private func readBudget(at url: URL) throws -> BudgetDocument {
        var coreBudget = BWBudget()

        try initializeBudget(&coreBudget, json: readText(from: url), url: url)
        defer {
            bw_budget_free(&coreBudget)
        }

        return try document(from: coreBudget, url: url)
    }

    private func initializeBudget(_ budget: inout BWBudget, title: Swift.String) throws {
        guard title.withCString({ bw_budget_init(&budget, $0) }) == 0 else {
            throw BudgetError.budgetCreationFailed
        }
    }

    private func initializeBudget(_ budget: inout BWBudget, json: Swift.String, url: URL) throws {
        let result = json.withCString { bw_budget_from_json_str(&budget, $0) }

        guard result == 0 else {
            throw BudgetError.budgetReadFailed(url)
        }
    }

    private func replaceTitle(_ title: Swift.String, in budget: inout BWBudget) throws {
        var newTitle = BWString()

        guard bw_string_init(&newTitle, &budget.arena) == 0 else {
            throw BudgetError.budgetCreationFailed
        }

        guard title.withCString({ bw_string_append(&newTitle, $0) }) == 0 else {
            throw BudgetError.budgetCreationFailed
        }

        budget.title = newTitle
    }

    private func jsonString(from budget: inout BWBudget) throws -> Swift.String {
        var jsonArena = BWArena()

        guard bw_arena_init(&jsonArena, Self.jsonArenaCapacity) == 0 else {
            throw BudgetError.jsonCreationFailed
        }

        defer {
            bw_arena_destroy(&jsonArena)
        }

        let jsonString = bw_budget_to_json_str(&budget, &jsonArena)

        guard let jsonData = jsonString.data else {
            throw BudgetError.jsonCreationFailed
        }

        let json = Swift.String(cString: jsonData)

        guard !json.isEmpty else {
            throw BudgetError.jsonCreationFailed
        }

        return json
    }

    private func document(from budget: BWBudget, url: URL) throws -> BudgetDocument {
        let title = budget.title.data.map { Swift.String(cString: $0) } ?? url.deletingPathExtension().lastPathComponent

        return BudgetDocument(
            coreID: Int(budget.id),
            url: url,
            title: title,
            categories: categories(from: budget)
        )
    }

    private func transaction(
        from transaction: BWTransaction,
        index: Int,
        categoryID: Int,
        categoryTitle: Swift.String,
        categoryType: BudgetCategoryType
    ) -> BudgetTransaction {
        let title = transaction.title.data.map { Swift.String(cString: $0) } ?? ""
        let description = transaction.description.data.map { Swift.String(cString: $0) } ?? ""

        return BudgetTransaction(
            id: "\(categoryType.id)-\(categoryID)-\(transaction.id)-\(index)",
            coreID: Int(transaction.id),
            title: title,
            description: description,
            date: transaction.date,
            amount: transaction.amount,
            categoryID: categoryID,
            categoryTitle: categoryTitle,
            categoryType: categoryType
        )
    }

    private func categories(from budget: BWBudget) -> [BudgetCategory] {
        guard let items = budget.categories.items else {
            return []
        }

        return (0..<budget.categories.length).compactMap { index in
            let category = items[index]

            guard let type = BudgetCategoryType(coreType: category.category_type) else {
                return nil
            }

            let title = category.title.data.map { Swift.String(cString: $0) } ?? ""
            let categoryID = Int(category.id)

            return BudgetCategory(
                id: "\(type.id)-\(category.id)-\(index)",
                coreID: categoryID,
                ordinal: Int(category.ordinal),
                title: title,
                amountPlanned: category.amount_planned,
                amountActual: category.amount_actual,
                amountAccumulated: category.amount_accumulated,
                type: type,
                transactions: transactions(
                    from: category.transactions,
                    categoryID: categoryID,
                    categoryTitle: title,
                    categoryType: type
                )
            )
        }
    }

    private func transactions(
        from transactionArray: BWTransactionArray,
        categoryID: Int,
        categoryTitle: Swift.String,
        categoryType: BudgetCategoryType
    ) -> [BudgetTransaction] {
        guard let items = transactionArray.items else {
            return []
        }

        return (0..<transactionArray.length).map { index in
            transaction(
                from: items[index],
                index: index,
                categoryID: categoryID,
                categoryTitle: categoryTitle,
                categoryType: categoryType
            )
        }
    }

    private func nextBudgetID(in vaultURL: URL) throws -> Int {
        let maxID = try vault.budgetFileURLs(in: vaultURL)
            .compactMap { try? readBudget(at: $0).coreID }
            .max() ?? 0

        return maxID + 1
    }

    private func accessBudget<T>(_ url: URL, operation: () throws -> T) throws -> T {
        if vault.isBudgetInConfiguredVault(url) {
            return try vault.accessVault(operation)
        }

        return try BudgetVault.accessSecurityScopedResource(url, operation: operation)
    }

    nonisolated private static func sortByFileName(_ lhs: BudgetDocument, _ rhs: BudgetDocument) -> Bool {
        lhs.url.lastPathComponent.localizedStandardCompare(rhs.url.lastPathComponent) == .orderedAscending
    }
}
