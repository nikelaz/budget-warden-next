/*
 * Budget Warden
 * Copyright (c) 2026 Lazarov & Co EOOD
 * Author: Nikola Lazarov
 *
 * Licensed under the Source-Available Educational License.
 * See the LICENSE file in the project root for full terms.
 *
 */

import Foundation

private let jsonSafeIntegerMax: UInt64 = 9_007_199_254_740_991

struct BudgetRow: Identifiable, Sendable {
    let url: URL
    let budgetID: Int
    let title: String

    var id: String {
        url.standardizedFileURL.path
    }
}

enum BudgetCategoryType: String, CaseIterable, Codable, Identifiable {
    case income
    case expenses
    case savings
    case debt

    var id: Self {
        self
    }

    var title: String {
        switch self {
        case .income:
            return "Income"
        case .expenses:
            return "Expenses"
        case .savings:
            return "Savings"
        case .debt:
            return "Debt"
        }
    }

    var supportsAccumulatedAmount: Bool {
        self == .savings || self == .debt
    }
}

enum CategoryAmountField {
    case planned
    case actual
    case accumulated
}

struct BWDate: Codable, Equatable, Sendable {
    var year: Int32
    var month: Int32
    var day: Int32

    init() {
        self.year = 0
        self.month = 0
        self.day = 0
    }

    init(year: Int32, month: Int32, day: Int32) {
        self.year = year
        self.month = month
        self.day = day
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        let parts = text.split(separator: "-")

        guard
            parts.count == 3,
            let year = Int32(parts[0]),
            let month = Int32(parts[1]),
            let day = Int32(parts[2]),
            BWDate.isValid(year: year, month: month, day: day)
        else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected date formatted as yyyy-MM-dd."
            )
        }

        self.year = year
        self.month = month
        self.day = day
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(formattedDate)
    }

    var formattedDate: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    nonisolated var sortValue: Int32 {
        year * 10_000 + month * 100 + day
    }

    static func isValid(year: Int32, month: Int32, day: Int32) -> Bool {
        guard year >= 1, month >= 1, month <= 12, day >= 1 else {
            return false
        }

        let daysInMonth: Int32
        switch month {
        case 1, 3, 5, 7, 8, 10, 12:
            daysInMonth = 31
        case 4, 6, 9, 11:
            daysInMonth = 30
        case 2:
            let leapYear = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
            daysInMonth = leapYear ? 29 : 28
        default:
            return false
        }

        return day <= daysInMonth
    }
}

struct BudgetTransaction: Codable, Identifiable, Sendable {
    var id: Int
    var title: String
    var description: String
    var date: BWDate
    var amount: UInt64
}

struct BudgetCategory: Codable, Identifiable, Sendable {
    var id: Int
    var ordinal: Int
    var title: String
    var amountPlanned: UInt64
    var amountActual: UInt64
    var amountAccumulated: UInt64
    var categoryType: BudgetCategoryType
    var transactions: [BudgetTransaction]

    enum CodingKeys: String, CodingKey {
        case id
        case ordinal
        case title
        case amountPlanned = "amount_planned"
        case amountActual = "amount_actual"
        case amountAccumulated = "amount_accumulated"
        case categoryType = "category_type"
        case transactions
    }
}

struct BWCategoryView: Sendable {
    var id: Int = 0
    var ordinal: Int = 0
    var title: String = ""
    var amount_planned: UInt64 = 0
    var amount_actual: UInt64 = 0
    var amount_accumulated: UInt64 = 0
    var category_type: BudgetCategoryType = .expenses
    var transaction_count: Int = 0

    func amount(_ field: CategoryAmountField) -> UInt64 {
        switch field {
        case .planned:
            return amount_planned
        case .actual:
            return amount_actual
        case .accumulated:
            return amount_accumulated
        }
    }

    var type: BudgetCategoryType? {
        category_type
    }
}

struct BWTransactionView: Sendable {
    var id: Int = 0
    var category_id: Int = 0
    var category_title: String = ""
    var category_type: BudgetCategoryType = .expenses
    var title: String = ""
    var description: String = ""
    var date: BWDate = BWDate()
    var amount: UInt64 = 0

    var categoryID: Int {
        category_id
    }

    var categoryType: BudgetCategoryType? {
        category_type
    }
}

struct Budget: Codable, Sendable {
    var id: Int
    var title: String
    var categories: [BudgetCategory]

    init(id: Int = 0, title: String, categories: [BudgetCategory] = []) {
        self.id = id
        self.title = title
        self.categories = categories
    }

    mutating func addCategory(title: String, amountPlanned: UInt64, amountAccumulated: UInt64, type: BudgetCategoryType) throws {
        guard amountPlanned <= jsonSafeIntegerMax, amountAccumulated <= jsonSafeIntegerMax else {
            throw BWError.categoryCreationFailed
        }
        guard type.supportsAccumulatedAmount || amountAccumulated == 0 else {
            throw BWError.categoryCreationFailed
        }

        categories.append(BudgetCategory(
            id: nextCategoryID(),
            ordinal: nextCategoryOrdinal(for: type),
            title: title,
            amountPlanned: amountPlanned,
            amountActual: 0,
            amountAccumulated: amountAccumulated,
            categoryType: type,
            transactions: []
        ))
    }

    mutating func updateCategory(_ update: CategoryUpdate) throws {
        guard let index = categories.firstIndex(where: { $0.id == update.categoryID }) else {
            throw BWError.categoryNotFound
        }
        guard categories[index].categoryType.supportsAccumulatedAmount || update.amountAccumulated == 0 else {
            throw BWError.categorySaveFailed
        }

        categories[index].title = update.title
        categories[index].amountPlanned = update.amountPlanned
        categories[index].amountAccumulated = update.amountAccumulated
    }

    mutating func removeCategory(id: Int) throws {
        guard let index = categories.firstIndex(where: { $0.id == id }) else {
            throw BWError.categoryNotFound
        }

        categories.remove(at: index)
    }

    mutating func reorderCategories(type: BudgetCategoryType, orderedCategoryIDs: [Int]) {
        var ordinal = 0

        for categoryID in orderedCategoryIDs {
            guard let index = categories.firstIndex(where: { $0.id == categoryID && $0.categoryType == type }) else {
                continue
            }

            categories[index].ordinal = ordinal
            ordinal += 1
        }

        let ordered = Set(orderedCategoryIDs)
        let remaining = categories
            .filter { $0.categoryType == type && !ordered.contains($0.id) }
            .sorted(by: Budget.categoryPrecedes)

        for category in remaining {
            guard let index = categories.firstIndex(where: { $0.id == category.id }) else {
                continue
            }

            categories[index].ordinal = ordinal
            ordinal += 1
        }
    }

    mutating func addTransaction(_ draft: TransactionDraft) throws {
        guard let categoryIndex = categories.firstIndex(where: { $0.id == draft.categoryID }) else {
            throw BWError.transactionCreationFailed
        }
        guard draft.amount <= jsonSafeIntegerMax else {
            throw BWError.transactionCreationFailed
        }
        guard UInt64.max - categories[categoryIndex].amountActual >= draft.amount else {
            throw BWError.transactionCreationFailed
        }

        let transaction = BudgetTransaction(
            id: nextTransactionID(),
            title: draft.title,
            description: draft.description,
            date: draft.date,
            amount: draft.amount
        )

        categories[categoryIndex].transactions.append(transaction)
        categories[categoryIndex].amountActual += draft.amount
    }

    mutating func updateTransaction(_ update: TransactionUpdate) throws {
        guard
            let sourceLocation = transactionLocation(id: update.transactionID),
            let targetCategoryIndex = categories.firstIndex(where: { $0.id == update.categoryID })
        else {
            throw BWError.transactionSaveFailed
        }

        let oldTransaction = categories[sourceLocation.categoryIndex].transactions[sourceLocation.transactionIndex]

        if sourceLocation.categoryIndex == targetCategoryIndex {
            if update.amount >= oldTransaction.amount {
                let increase = update.amount - oldTransaction.amount
                guard UInt64.max - categories[targetCategoryIndex].amountActual >= increase else {
                    throw BWError.transactionSaveFailed
                }
                categories[targetCategoryIndex].amountActual += increase
            } else {
                categories[targetCategoryIndex].amountActual -= oldTransaction.amount - update.amount
            }

            categories[targetCategoryIndex].transactions[sourceLocation.transactionIndex] = BudgetTransaction(
                id: update.transactionID,
                title: update.title,
                description: update.description,
                date: update.date,
                amount: update.amount
            )
            return
        }

        guard UInt64.max - categories[targetCategoryIndex].amountActual >= update.amount else {
            throw BWError.transactionSaveFailed
        }

        categories[sourceLocation.categoryIndex].transactions.remove(at: sourceLocation.transactionIndex)
        categories[sourceLocation.categoryIndex].amountActual -= oldTransaction.amount
        categories[targetCategoryIndex].transactions.append(BudgetTransaction(
            id: update.transactionID,
            title: update.title,
            description: update.description,
            date: update.date,
            amount: update.amount
        ))
        categories[targetCategoryIndex].amountActual += update.amount
    }

    mutating func removeTransaction(id: Int) throws {
        guard let location = transactionLocation(id: id) else {
            throw BWError.transactionNotFound
        }

        let transaction = categories[location.categoryIndex].transactions.remove(at: location.transactionIndex)
        categories[location.categoryIndex].amountActual -= transaction.amount
    }

    func categoryIDs(for type: BudgetCategoryType) -> [Int] {
        categories
            .filter { $0.categoryType == type }
            .sorted(by: Budget.categoryPrecedes)
            .map(\.id)
    }

    func categoryIDs() -> [Int] {
        BudgetCategoryType.allCases.flatMap { categoryIDs(for: $0) }
    }

    func transactionIDs() -> [Int] {
        categories
            .flatMap(\.transactions)
            .sorted(by: Budget.transactionPrecedes)
            .map(\.id)
    }

    func categoryTotal(type: BudgetCategoryType, field: CategoryAmountField) -> UInt64 {
        categories.reduce(0) { total, category in
            guard category.categoryType == type else {
                return total
            }

            let amount = category.amount(field)
            return UInt64.max - total < amount ? UInt64.max : total + amount
        }
    }

    func categoryView(id: Int) -> BWCategoryView? {
        guard let category = categories.first(where: { $0.id == id }) else {
            return nil
        }

        return BWCategoryView(
            id: category.id,
            ordinal: category.ordinal,
            title: category.title,
            amount_planned: category.amountPlanned,
            amount_actual: category.amountActual,
            amount_accumulated: category.amountAccumulated,
            category_type: category.categoryType,
            transaction_count: category.transactions.count
        )
    }

    func transactionView(id: Int) -> BWTransactionView? {
        for category in categories {
            guard let transaction = category.transactions.first(where: { $0.id == id }) else {
                continue
            }

            return BWTransactionView(
                id: transaction.id,
                category_id: category.id,
                category_title: category.title,
                category_type: category.categoryType,
                title: transaction.title,
                description: transaction.description,
                date: transaction.date,
                amount: transaction.amount
            )
        }

        return nil
    }

    private func nextCategoryID() -> Int {
        (categories.map(\.id).max() ?? 0) + 1
    }

    private func nextCategoryOrdinal(for type: BudgetCategoryType) -> Int {
        (categories.filter { $0.categoryType == type }.map(\.ordinal).max() ?? -1) + 1
    }

    private func nextTransactionID() -> Int {
        (categories.flatMap(\.transactions).map(\.id).max() ?? 0) + 1
    }

    private func transactionLocation(id: Int) -> (categoryIndex: Int, transactionIndex: Int)? {
        for categoryIndex in categories.indices {
            guard let transactionIndex = categories[categoryIndex].transactions.firstIndex(where: { $0.id == id }) else {
                continue
            }

            return (categoryIndex, transactionIndex)
        }

        return nil
    }

    nonisolated private static func categoryPrecedes(_ lhs: BudgetCategory, _ rhs: BudgetCategory) -> Bool {
        if lhs.ordinal != rhs.ordinal {
            return lhs.ordinal < rhs.ordinal
        }

        return lhs.id < rhs.id
    }

    nonisolated private static func transactionPrecedes(_ lhs: BudgetTransaction, _ rhs: BudgetTransaction) -> Bool {
        if lhs.date.sortValue != rhs.date.sortValue {
            return lhs.date.sortValue > rhs.date.sortValue
        }

        return lhs.id > rhs.id
    }
}

private extension BudgetCategory {
    func amount(_ field: CategoryAmountField) -> UInt64 {
        switch field {
        case .planned:
            return amountPlanned
        case .actual:
            return amountActual
        case .accumulated:
            return amountAccumulated
        }
    }
}

extension String {
    nonisolated func swiftString(default fallback: String = "") -> String {
        isEmpty ? fallback : self
    }
}
