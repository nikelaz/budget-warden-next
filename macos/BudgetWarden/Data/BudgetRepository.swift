import Foundation

protocol BudgetRepository {
    func loadBudgets() throws -> [BudgetDocument]
    func createBudget(_ draft: BudgetDraft) throws -> BudgetDocument
    func openBudget(at url: URL) throws -> BudgetDocument
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

    init(vault: BudgetVault = .shared, fileStore: BudgetFileStore = BudgetFileStore()) {
        self.vault = vault
        self.fileStore = fileStore
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
            let handle = try CoreBudgetHandle(title: uniqueBudget.title)
            let budgetID = try nextBudgetID(in: vaultURL)

            if !draft.templateUrl.isEmpty {
                let templateResult = draft.templateUrl.withCString {
                    budget_init_from_template(&handle.budget, $0)
                }

                guard templateResult == 0 else {
                    throw BudgetVaultError.budgetCreationFailed
                }
                
                var newTitle = BWString()
                bw_string_init(&newTitle)
                let _ = uniqueBudget.title.withCString {
                    bw_string_append(&newTitle, $0)
                }
                handle.budget.title = newTitle
            }

            handle.withUnsafeMutableBudget { budget in
                budget.id = Int32(budgetID)
            }

            try fileStore.writeText(handle.jsonString(), to: uniqueBudget.url)
            return try readBudget(at: uniqueBudget.url)
        }
    }

    func openBudget(at url: URL) throws -> BudgetDocument {
        try accessBudget(url) {
            try readBudget(at: url)
        }
    }

    func addCategory(_ draft: CategoryDraft, to budget: BudgetDocument) throws -> BudgetDocument {
        try mutateBudget(budget) { coreBudget in
            var category = BWCoreCategory()

            guard category_init(&category, draft.title, draft.amountPlanned, 0, draft.amountAccumulated, draft.type.coreType) == 0 else {
                throw BudgetVaultError.categoryCreationFailed
            }

            guard budget_add_category(&coreBudget, category) == 0 else {
                category_free(&category)
                throw BudgetVaultError.categorySaveFailed
            }
        }
    }

    func updateCategory(_ update: CategoryUpdate, in budget: BudgetDocument) throws -> BudgetDocument {
        try mutateBudget(budget) { coreBudget in
            let result = update.title.withCString { title in
                let coreUpdate = CoreCategoryUpdate(
                    title: title,
                    amount_planned: update.amountPlanned,
                    amount_accumulated: update.amountAccumulated
                )

                return budget_update_category(&coreBudget, Int32(update.categoryID), coreUpdate)
            }

            guard result == 0 else {
                throw BudgetVaultError.categorySaveFailed
            }
        }
    }

    func removeCategory(_ category: BudgetCategory, from budget: BudgetDocument) throws -> BudgetDocument {
        try mutateBudget(budget) { coreBudget in
            guard budget_remove_category(&coreBudget, Int32(category.coreID)) == 0 else {
                throw BudgetVaultError.categoryNotFound
            }
        }
    }

    func reorderCategories(type: BudgetCategoryType, orderedCategoryIDs: [Int], in budget: BudgetDocument) throws -> BudgetDocument {
        try mutateBudget(budget) { coreBudget in
            let coreCategoryIDs = orderedCategoryIDs.map(Int32.init)
            let result = coreCategoryIDs.withUnsafeBufferPointer { buffer in
                budget_reorder_categories(&coreBudget, type.coreType, buffer.baseAddress, buffer.count)
            }

            guard result == 0 else {
                throw BudgetVaultError.categorySaveFailed
            }
        }
    }

    func addTransaction(_ draft: TransactionDraft, to budget: BudgetDocument) throws -> BudgetDocument {
        try mutateBudget(budget) { coreBudget in
            var transaction = Transaction()

            guard transaction_init(
                &transaction,
                draft.title,
                draft.description,
                draft.date,
                draft.amount
            ) == 0 else {
                throw BudgetVaultError.transactionCreationFailed
            }

            guard budget_add_transaction(&coreBudget, Int32(draft.categoryID), transaction) == 0 else {
                transaction_free(&transaction)
                throw BudgetVaultError.transactionSaveFailed
            }
        }
    }

    func updateTransaction(_ update: TransactionUpdate, in budget: BudgetDocument) throws -> BudgetDocument {
        try mutateBudget(budget) { coreBudget in
            let result = update.title.withCString { title in
                update.description.withCString { description in
                    let coreUpdate = CoreTransactionUpdate(
                        category_id: Int32(update.categoryID),
                        title: title,
                        description: description,
                        date: update.date,
                        amount: update.amount
                    )

                    return budget_update_transaction(&coreBudget, Int32(update.transactionID), coreUpdate)
                }
            }

            guard result == 0 else {
                throw BudgetVaultError.transactionSaveFailed
            }
        }
    }

    func removeTransaction(_ transaction: BudgetTransaction, from budget: BudgetDocument) throws -> BudgetDocument {
        try mutateBudget(budget) { coreBudget in
            guard budget_remove_transaction(&coreBudget, Int32(transaction.coreID)) == 0 else {
                throw BudgetVaultError.transactionNotFound
            }
        }
    }

    func removeBudget(_ budget: BudgetDocument) throws {
        try accessBudget(budget.url) {
            try fileStore.remove(budget.url)
        }
    }

    private func mutateBudget(
        _ budget: BudgetDocument,
        mutation: (inout Budget) throws -> Void
    ) throws -> BudgetDocument {
        try accessBudget(budget.url) {
            let handle = try readHandle(at: budget.url)
            try handle.withUnsafeMutableBudget(mutation)
            try fileStore.writeText(handle.jsonString(), to: budget.url)
            return try handle.document(url: budget.url)
        }
    }

    private func readBudget(at url: URL) throws -> BudgetDocument {
        try readHandle(at: url).document(url: url)
    }

    private func readHandle(at url: URL) throws -> CoreBudgetHandle {
        try CoreBudgetHandle(json: fileStore.readText(from: url), url: url)
    }

    private func nextBudgetID(in vaultURL: URL) throws -> Int {
        let maxID = try vault.budgetFileURLs(in: vaultURL)
            .compactMap { try? readBudget(at: $0).id }
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
