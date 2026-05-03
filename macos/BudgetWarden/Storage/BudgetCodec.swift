import Foundation

enum BudgetCodec {
    static func makeJSON(from draft: BudgetDraft) throws -> Swift.String {
        try makeJSON(title: draft.title)
    }

    static func makeJSON(title: Swift.String) throws -> Swift.String {
        var budget = Budget()

        guard budget_init(&budget, title) == 0 else {
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
            categories: categories(from: budget)
        )
    }

    static func addCategory(_ draft: CategoryDraft, to url: URL) throws -> BudgetDocument {
        var budget = try readCoreBudget(from: url)

        defer {
            budget_free(&budget)
        }

        var category = Category()

        guard category_init(&category, draft.title, draft.amountPlanned, 0, draft.amountAccumulated, draft.type.coreType) == 0 else {
            throw BudgetVaultError.categoryCreationFailed
        }

        category.id = nextCategoryID(in: budget)
        category.ordinal = nextCategoryOrdinal(in: budget, type: draft.type.coreType)

        guard category_array_push_move(&budget.categories, category) == 0 else {
            category_free(&category)
            throw BudgetVaultError.categorySaveFailed
        }

        try writeBudget(&budget, to: url)
        return try readBudget(from: url)
    }

    static func updateCategory(_ update: CategoryUpdate, in url: URL) throws -> BudgetDocument {
        var budget = try readCoreBudget(from: url)

        defer {
            budget_free(&budget)
        }

        guard let categories = budget.categories.items else {
            throw BudgetVaultError.categoryNotFound
        }

        guard let categoryIndex = (0..<budget.categories.length).first(where: {
            Int(categories[$0].id) == update.categoryID
        }) else {
            throw BudgetVaultError.categoryNotFound
        }

        let category = categories.advanced(by: categoryIndex)
        let categoryType = category.pointee.category_type

        guard
            categoryType == CATEGORY_SAVINGS ||
            categoryType == CATEGORY_DEBT ||
            update.amountAccumulated == 0
        else {
            throw BudgetVaultError.categorySaveFailed
        }

        var title = BWString()

        guard bw_string_init(&title) == 0 else {
            throw BudgetVaultError.categorySaveFailed
        }

        guard bw_string_append(&title, update.title) == 0 else {
            bw_string_free(&title)
            throw BudgetVaultError.categorySaveFailed
        }

        var previousTitle = category.pointee.title
        bw_string_free(&previousTitle)
        category.pointee.title = title
        category.pointee.amount_planned = update.amountPlanned
        category.pointee.amount_accumulated = update.amountAccumulated

        try writeBudget(&budget, to: url)
        return try readBudget(from: url)
    }

    static func removeCategory(categoryID: Int, from url: URL) throws -> BudgetDocument {
        var budget = try readCoreBudget(from: url)

        defer {
            budget_free(&budget)
        }

        guard let categories = budget.categories.items else {
            throw BudgetVaultError.categoryNotFound
        }

        guard let categoryIndex = (0..<budget.categories.length).first(where: {
            Int(categories[$0].id) == categoryID
        }) else {
            throw BudgetVaultError.categoryNotFound
        }

        category_free(categories.advanced(by: categoryIndex))

        if categoryIndex < budget.categories.length - 1 {
            for index in categoryIndex..<(budget.categories.length - 1) {
                categories[index] = categories[index + 1]
            }
        }

        budget.categories.length -= 1

        try writeBudget(&budget, to: url)
        return try readBudget(from: url)
    }

    static func reorderCategories(type: BudgetCategoryType, orderedCategoryIDs: [Int], in url: URL) throws -> BudgetDocument {
        var budget = try readCoreBudget(from: url)

        defer {
            budget_free(&budget)
        }

        guard let categories = budget.categories.items else {
            throw BudgetVaultError.categoryNotFound
        }

        var ordinal: Int32 = 0

        for categoryID in orderedCategoryIDs {
            guard let categoryIndex = (0..<budget.categories.length).first(where: {
                Int(categories[$0].id) == categoryID && categories[$0].category_type == type.coreType
            }) else {
                continue
            }

            categories[categoryIndex].ordinal = ordinal
            ordinal += 1
        }

        let orderedIDs = Set(orderedCategoryIDs)
        let remainingIndices = (0..<budget.categories.length)
            .filter {
                categories[$0].category_type == type.coreType &&
                !orderedIDs.contains(Int(categories[$0].id))
            }
            .sorted {
                if categories[$0].ordinal != categories[$1].ordinal {
                    return categories[$0].ordinal < categories[$1].ordinal
                }

                return categories[$0].id < categories[$1].id
            }

        for categoryIndex in remainingIndices {
            categories[categoryIndex].ordinal = ordinal
            ordinal += 1
        }

        try writeBudget(&budget, to: url)
        return try readBudget(from: url)
    }

    static func addTransaction(_ draft: TransactionDraft, to url: URL) throws -> BudgetDocument {
        var budget = try readCoreBudget(from: url)

        defer {
            budget_free(&budget)
        }

        guard let categories = budget.categories.items else {
            throw BudgetVaultError.transactionCategoryNotFound
        }

        guard let categoryIndex = (0..<budget.categories.length).first(where: {
            Int(categories[$0].id) == draft.categoryID
        }) else {
            throw BudgetVaultError.transactionCategoryNotFound
        }

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

        transaction.id = nextTransactionID(in: budget)

        guard category_add_transaction(categories.advanced(by: categoryIndex), transaction) == 0 else {
            transaction_free(&transaction)
            throw BudgetVaultError.transactionSaveFailed
        }

        try writeBudget(&budget, to: url)
        return try readBudget(from: url)
    }

    static func updateTransaction(_ update: TransactionUpdate, in url: URL) throws -> BudgetDocument {
        var budget = try readCoreBudget(from: url)

        defer {
            budget_free(&budget)
        }

        guard let categories = budget.categories.items else {
            throw BudgetVaultError.transactionCategoryNotFound
        }

        guard let source = transactionLocation(transactionID: update.transactionID, in: budget) else {
            throw BudgetVaultError.transactionNotFound
        }

        guard let targetCategoryIndex = (0..<budget.categories.length).first(where: {
            Int(categories[$0].id) == update.categoryID
        }) else {
            throw BudgetVaultError.transactionCategoryNotFound
        }

        let sourceCategory = categories.advanced(by: source.categoryIndex)
        let sourceTransaction = sourceCategory.pointee.transactions.items.advanced(by: source.transactionIndex)

        if source.categoryIndex == targetCategoryIndex {
            var title = BWString()

            guard bw_string_init(&title) == 0 else {
                throw BudgetVaultError.transactionSaveFailed
            }

            guard bw_string_append(&title, update.title) == 0 else {
                bw_string_free(&title)
                throw BudgetVaultError.transactionSaveFailed
            }

            var description = BWString()

            guard bw_string_init(&description) == 0 else {
                bw_string_free(&title)
                throw BudgetVaultError.transactionSaveFailed
            }

            guard bw_string_append(&description, update.description) == 0 else {
                bw_string_free(&title)
                bw_string_free(&description)
                throw BudgetVaultError.transactionSaveFailed
            }

            let oldAmount = sourceTransaction.pointee.amount

            if update.amount >= oldAmount {
                let increase = update.amount - oldAmount
                guard UInt64.max - sourceCategory.pointee.amount_actual >= increase else {
                    bw_string_free(&title)
                    bw_string_free(&description)
                    throw BudgetVaultError.transactionSaveFailed
                }

                sourceCategory.pointee.amount_actual += increase
            } else {
                let decrease = oldAmount - update.amount
                guard sourceCategory.pointee.amount_actual >= decrease else {
                    bw_string_free(&title)
                    bw_string_free(&description)
                    throw BudgetVaultError.transactionSaveFailed
                }

                sourceCategory.pointee.amount_actual -= decrease
            }

            var previousTitle = sourceTransaction.pointee.title
            var previousDescription = sourceTransaction.pointee.description
            bw_string_free(&previousTitle)
            bw_string_free(&previousDescription)

            sourceTransaction.pointee.title = title
            sourceTransaction.pointee.description = description
            sourceTransaction.pointee.date = update.date
            sourceTransaction.pointee.amount = update.amount
        } else {
            var replacement = Transaction()

            guard transaction_init(
                &replacement,
                update.title,
                update.description,
                update.date,
                update.amount
            ) == 0 else {
                throw BudgetVaultError.transactionCreationFailed
            }

            replacement.id = Int32(update.transactionID)

            guard category_remove_transaction(sourceCategory, sourceTransaction) == 0 else {
                transaction_free(&replacement)
                throw BudgetVaultError.transactionSaveFailed
            }

            guard category_add_transaction(categories.advanced(by: targetCategoryIndex), replacement) == 0 else {
                transaction_free(&replacement)
                throw BudgetVaultError.transactionSaveFailed
            }
        }

        try writeBudget(&budget, to: url)
        return try readBudget(from: url)
    }

    static func removeTransaction(_ transaction: BudgetTransaction, from url: URL) throws -> BudgetDocument {
        var budget = try readCoreBudget(from: url)

        defer {
            budget_free(&budget)
        }

        guard let source = transactionLocation(transactionID: transaction.coreID, in: budget) else {
            throw BudgetVaultError.transactionNotFound
        }

        guard let categories = budget.categories.items else {
            throw BudgetVaultError.transactionCategoryNotFound
        }

        let category = categories.advanced(by: source.categoryIndex)
        let item = category.pointee.transactions.items.advanced(by: source.transactionIndex)

        guard category_remove_transaction(category, item) == 0 else {
            throw BudgetVaultError.transactionSaveFailed
        }

        try writeBudget(&budget, to: url)
        return try readBudget(from: url)
    }

    private static func writeBudget(_ budget: inout Budget, to url: URL) throws {
        var jsonString = budget_to_json_str(&budget)

        defer {
            bw_string_free(&jsonString)
        }

        guard let jsonData = jsonString.data else {
            throw BudgetVaultError.jsonCreationFailed
        }

        try Swift.String(cString: jsonData).write(to: url, atomically: true, encoding: .utf8)
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

        return (0..<budget.categories.length).compactMap { index -> BudgetCategory? in
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

    private static func transactions(
        from transactionArray: TransactionArray,
        categoryID: Int,
        categoryTitle: Swift.String,
        categoryType: BudgetCategoryType
    ) -> [BudgetTransaction] {
        guard let items = transactionArray.items else {
            return []
        }

        return (0..<transactionArray.length).map { index in
            let transaction = items[index]
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
    }

    private static func nextCategoryID(in budget: Budget) -> Int32 {
        guard let items = budget.categories.items else {
            return 1
        }

        let maxID = (0..<budget.categories.length).map { items[$0].id }.max() ?? 0
        return maxID + 1
    }

    private static func nextCategoryOrdinal(in budget: Budget, type: CategoryType) -> Int32 {
        guard let items = budget.categories.items else {
            return 0
        }

        let ordinals = (0..<budget.categories.length)
            .filter { items[$0].category_type == type }
            .map { items[$0].ordinal }

        return (ordinals.max() ?? -1) + 1
    }

    private static func nextTransactionID(in budget: Budget) -> Int32 {
        guard let categories = budget.categories.items else {
            return 1
        }

        var maxID: Int32 = 0

        for categoryIndex in 0..<budget.categories.length {
            guard let transactions = categories[categoryIndex].transactions.items else {
                continue
            }

            let categoryMaxID = (0..<categories[categoryIndex].transactions.length)
                .map { transactions[$0].id }
                .max() ?? 0
            maxID = max(maxID, Int32(categoryMaxID))
        }

        return maxID + 1
    }

    private static func transactionLocation(transactionID: Int, in budget: Budget) -> (categoryIndex: Int, transactionIndex: Int)? {
        guard let categories = budget.categories.items else {
            return nil
        }

        for categoryIndex in 0..<budget.categories.length {
            guard let transactions = categories[categoryIndex].transactions.items else {
                continue
            }

            if let transactionIndex = (0..<categories[categoryIndex].transactions.length).first(where: {
                Int(transactions[$0].id) == transactionID
            }) {
                return (categoryIndex, transactionIndex)
            }
        }

        return nil
    }

}
