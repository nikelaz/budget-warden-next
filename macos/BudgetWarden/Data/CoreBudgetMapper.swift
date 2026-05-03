import Foundation

enum CoreBudgetMapper {
    static func document(from budget: Budget, url: URL) throws -> BudgetDocument {
        let title = budget.title.data.map { Swift.String(cString: $0) } ?? url.deletingPathExtension().lastPathComponent

        return BudgetDocument(
            id: Int(budget.id),
            url: url,
            title: title,
            categories: categories(from: budget)
        )
    }

    static func transaction(
        from transaction: Transaction,
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
            transaction(
                from: items[index],
                index: index,
                categoryID: categoryID,
                categoryTitle: categoryTitle,
                categoryType: categoryType
            )
        }
    }
}
