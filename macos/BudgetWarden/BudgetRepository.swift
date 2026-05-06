import Foundation

protocol BudgetRepository {
    func loadBudgets() throws -> [BudgetDocument]
    func createBudget(_ draft: BudgetDraft) throws -> BudgetDocument
    func openBudget(at url: URL) throws -> BudgetDocument
    func activateBudget(_ budget: BudgetDocument) throws -> BudgetDocument
    func closeActiveBudget()
    func addCategory(_ draft: CategoryDraft, to budget: BudgetDocument) throws -> BudgetDocument
    func updateCategory(_ update: CategoryUpdate, in budget: BudgetDocument) throws -> BudgetDocument
    func removeCategory(_ category: BudgetCategory, from budget: BudgetDocument) throws -> BudgetDocument
    func reorderCategories(type: BudgetCategoryType, orderedCategoryIDs: [Int], in budget: BudgetDocument) throws -> BudgetDocument
    func addTransaction(_ draft: TransactionDraft, to budget: BudgetDocument) throws -> BudgetDocument
    func updateTransaction(_ update: TransactionUpdate, in budget: BudgetDocument) throws -> BudgetDocument
    func removeTransaction(_ transaction: BudgetTransaction, from budget: BudgetDocument) throws -> BudgetDocument
    func removeBudget(_ budget: BudgetDocument) throws
}

final class CoreBudgetRepository: BudgetRepository {
    private let vault: BudgetVault
    private let fileStore: BudgetFileStore
    private var activeBudget = BWBudget()
    private var activeBudgetURL: URL?
    private var jsonArena = BWArena()
    private var isJsonArenaInitialized = false
    private static let jsonArenaCapacity = 1024 * 1024

    init(vault: BudgetVault = .shared, fileStore: BudgetFileStore = BudgetFileStore()) {
        self.vault = vault
        self.fileStore = fileStore
    }

    deinit {
        closeActiveBudget()

        if isJsonArenaInitialized {
            bw_arena_destroy(&jsonArena)
        }
    }

    func loadBudgets() throws -> [BudgetDocument] {
        let vaultURL = try vault.resolveVaultURL()

        return try vault.accessVault {
            try vault.budgetFileURLs(in: vaultURL)
                .compactMap { try? readBudgetSnapshot(at: $0) }
                .sorted(by: Self.sortByFileName)
        }
    }

    func createBudget(_ draft: BudgetDraft) throws -> BudgetDocument {
        let vaultURL = try vault.resolveVaultURL()

        return try vault.accessVault {
            let uniqueBudget = vault.uniqueBudgetLocation(for: draft.title, in: vaultURL)
            var coreBudget = BWBudget()

            try initializeBudget(&coreBudget, title: uniqueBudget.title)
            defer {
                bw_budget_free(&coreBudget)
            }

            let budgetID = try nextBudgetID(in: vaultURL)

            if !draft.templateUrl.isEmpty {
                let templateResult = draft.templateUrl.withCString {
                    bw_budget_init_from_template(&coreBudget, $0)
                }

                guard templateResult == 0 else {
                    throw BudgetVaultError.budgetCreationFailed
                }

                try replaceTitle(uniqueBudget.title, in: &coreBudget)
            }

            coreBudget.id = Int32(budgetID)

            try fileStore.writeText(jsonString(from: &coreBudget), to: uniqueBudget.url)
            return try activateBudgetAt(uniqueBudget.url)
        }
    }

    func openBudget(at url: URL) throws -> BudgetDocument {
        try accessBudget(url) {
            try activateBudgetAt(url)
        }
    }

    func activateBudget(_ budget: BudgetDocument) throws -> BudgetDocument {
        try accessBudget(budget.url) {
            if isActiveBudget(at: budget.url) {
                return try document(from: activeBudget, url: budget.url)
            }

            return try activateBudgetAt(budget.url)
        }
    }

    func closeActiveBudget() {
        guard activeBudgetURL != nil else {
            return
        }

        bw_budget_free(&activeBudget)
        activeBudget = BWBudget()
        activeBudgetURL = nil
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
                throw BudgetVaultError.categoryCreationFailed
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
                throw BudgetVaultError.categorySaveFailed
            }
        }
    }

    func removeCategory(_ category: BudgetCategory, from budget: BudgetDocument) throws -> BudgetDocument {
        try mutateBudget(budget) { coreBudget in
            guard bw_budget_remove_category(&coreBudget, Int32(category.coreID)) == 0 else {
                throw BudgetVaultError.categoryNotFound
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
                throw BudgetVaultError.categorySaveFailed
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
                throw BudgetVaultError.transactionCreationFailed
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
                throw BudgetVaultError.transactionSaveFailed
            }
        }
    }

    func removeTransaction(_ transaction: BudgetTransaction, from budget: BudgetDocument) throws -> BudgetDocument {
        try mutateBudget(budget) { coreBudget in
            guard bw_budget_remove_transaction(&coreBudget, Int32(transaction.coreID)) == 0 else {
                throw BudgetVaultError.transactionNotFound
            }
        }
    }

    func removeBudget(_ budget: BudgetDocument) throws {
        try accessBudget(budget.url) {
            if isActiveBudget(at: budget.url) {
                closeActiveBudget()
            }

            try fileStore.remove(budget.url)
        }
    }

    private func mutateBudget(
        _ budget: BudgetDocument,
        mutation: (inout BWBudget) throws -> Void
    ) throws -> BudgetDocument {
        try accessBudget(budget.url) {
            if !isActiveBudget(at: budget.url) {
                _ = try activateBudgetAt(budget.url)
            }

            try mutation(&activeBudget)
            try fileStore.writeText(jsonString(from: &activeBudget), to: budget.url)
            return try document(from: activeBudget, url: budget.url)
        }
    }

    private func activateBudgetAt(_ url: URL) throws -> BudgetDocument {
        closeActiveBudget()

        do {
            try initializeBudget(&activeBudget, json: fileStore.readText(from: url), url: url)
            activeBudgetURL = url
            return try document(from: activeBudget, url: url)
        } catch {
            activeBudget = BWBudget()
            activeBudgetURL = nil
            throw error
        }
    }

    private func readBudgetSnapshot(at url: URL) throws -> BudgetDocument {
        var coreBudget = BWBudget()

        try initializeBudget(&coreBudget, json: fileStore.readText(from: url), url: url)
        defer {
            bw_budget_free(&coreBudget)
        }

        return try document(from: coreBudget, url: url)
    }

    private func initializeBudget(_ budget: inout BWBudget, title: Swift.String) throws {
        guard title.withCString({ bw_budget_init(&budget, $0) }) == 0 else {
            throw BudgetVaultError.budgetCreationFailed
        }
    }

    private func initializeBudget(_ budget: inout BWBudget, json: Swift.String, url: URL) throws {
        let result = json.withCString { bw_budget_from_json_str(&budget, $0) }

        guard result == 0 else {
            throw BudgetVaultError.budgetReadFailed(url)
        }
    }

    private func replaceTitle(_ title: Swift.String, in budget: inout BWBudget) throws {
        var newTitle = BWString()

        guard bw_string_init(&newTitle, &budget.arena) == 0 else {
            throw BudgetVaultError.budgetCreationFailed
        }

        guard title.withCString({ bw_string_append(&newTitle, $0) }) == 0 else {
            throw BudgetVaultError.budgetCreationFailed
        }

        budget.title = newTitle
    }

    private func jsonString(from budget: inout BWBudget) throws -> Swift.String {
        try ensureJsonArena()
        bw_arena_reset(&jsonArena)

        let jsonString = bw_budget_to_json_str(&budget, &jsonArena)

        guard let jsonData = jsonString.data else {
            throw BudgetVaultError.jsonCreationFailed
        }

        let json = Swift.String(cString: jsonData)

        guard !json.isEmpty else {
            throw BudgetVaultError.jsonCreationFailed
        }

        return json
    }

    private func ensureJsonArena() throws {
        guard !isJsonArenaInitialized else {
            return
        }

        guard bw_arena_init(&jsonArena, Self.jsonArenaCapacity) == 0 else {
            throw BudgetVaultError.jsonCreationFailed
        }

        isJsonArenaInitialized = true
    }

    private func document(from budget: BWBudget, url: URL) throws -> BudgetDocument {
        let title = budget.title.data.map { Swift.String(cString: $0) } ?? url.deletingPathExtension().lastPathComponent

        return BudgetDocument(
            id: Int(budget.id),
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
            .compactMap { try? readBudgetSnapshot(at: $0).id }
            .max() ?? 0

        return maxID + 1
    }

    private func accessBudget<T>(_ url: URL, operation: () throws -> T) throws -> T {
        if vault.isBudgetInConfiguredVault(url) {
            return try vault.accessVault(operation)
        }

        return try BudgetVault.accessSecurityScopedResource(url, operation: operation)
    }

    private func isActiveBudget(at url: URL) -> Bool {
        activeBudgetURL.map { sameFile($0, url) } ?? false
    }

    private func sameFile(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.standardizedFileURL == rhs.standardizedFileURL
    }

    nonisolated private static func sortByFileName(_ lhs: BudgetDocument, _ rhs: BudgetDocument) -> Bool {
        lhs.url.lastPathComponent.localizedStandardCompare(rhs.url.lastPathComponent) == .orderedAscending
    }
}
