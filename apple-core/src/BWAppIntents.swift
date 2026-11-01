/*
 * Budget Warden
 * Copyright (c) 2026 Lazarov & Co EOOD
 * Author: Nikola Lazarov
 *
 * Licensed under the Source-Available Educational License.
 * See the LICENSE file in the project root for full terms.
 */

import AppIntents
import Foundation

private let intentDataSourceKey = "BudgetWarden.IntentDataSource"

@MainActor
public protocol BWIntentDataSource: AnyObject, Sendable {
    func intentBudgets() async throws -> [BWShortcutBudget]
    func intentCreateBudget(title: String, templateID: String) async throws -> BWShortcutBudget
    func intentRenameBudget(id: UUID, title: String) async throws -> BWShortcutBudget
    func intentDeleteBudget(id: UUID) async throws
    func intentCategories(budgetID: UUID?, categoryType: BWShortcutCategoryType?) async throws -> [BWShortcutCategory]
    func intentCreateCategory(budgetID: UUID, title: String, plannedAmount: Int64, categoryType: BWShortcutCategoryType) async throws -> BWShortcutCategory
    func intentUpdateCategory(id: UUID, budgetID: UUID, title: String?, plannedAmount: Int64?, categoryType: BWShortcutCategoryType?) async throws -> BWShortcutCategory
    func intentDeleteCategory(id: UUID, budgetID: UUID) async throws
    func intentTransactions(budgetID: UUID?, categoryID: UUID?, search: String?, limit: Int) async throws -> [BWShortcutTransaction]
    func intentCreateTransaction(budgetID: UUID, categoryID: UUID, title: String, description: String?, date: Date, amount: Int64) async throws -> BWShortcutTransaction
    func intentUpdateTransaction(id: UUID, budgetID: UUID, title: String?, description: String?, date: Date?, amount: Int64?, categoryID: UUID?) async throws -> BWShortcutTransaction
    func intentDeleteTransaction(id: UUID, budgetID: UUID) async throws
    func intentReport(budgetID: UUID) async throws -> BWShortcutReport
}

@MainActor
public enum BWIntentRegistration {
    public static func register(_ dataSource: any BWIntentDataSource) {
        AppDependencyManager.shared.add(key: intentDataSourceKey, dependency: dataSource)
    }
}

public enum BWShortcutCategoryType: String, AppEnum, CaseIterable, Codable, Hashable, Sendable {
    case income
    case expenses
    case savings
    case debt

    public static var typeDisplayRepresentation: TypeDisplayRepresentation { TypeDisplayRepresentation(name: "Category Type") }
    public static var caseDisplayRepresentations: [BWShortcutCategoryType: DisplayRepresentation] { [
        .income: "Income",
        .expenses: "Expenses",
        .savings: "Savings",
        .debt: "Debt",
    ] }

    public var coreValue: BWCategoryType {
        switch self {
        case .income: .income
        case .expenses: .expenses
        case .savings: .savings
        case .debt: .debt
        }
    }

    public init(_ value: BWCategoryType) {
        switch value {
        case .income: self = .income
        case .expenses: self = .expenses
        case .savings: self = .savings
        case .debt: self = .debt
        }
    }
}

public enum BWShortcutTemplate: String, AppEnum, CaseIterable, Codable, Hashable, Sendable {
    case monthly = "basic-monthly"
    case weekly = "weekly-personal"
    case biweekly = "biweekly-paycheck"
    case freelancer = "freelancer-monthly"
    case smallBusiness = "small-business-monthly"
    case event = "event-planning"
    case vacation
    case businessTrip = "business-trip"
    case empty

    public static var typeDisplayRepresentation: TypeDisplayRepresentation { TypeDisplayRepresentation(name: "Budget Template") }
    public static var caseDisplayRepresentations: [BWShortcutTemplate: DisplayRepresentation] { [
        .monthly: "Monthly Budget",
        .weekly: "Weekly Personal",
        .biweekly: "Biweekly Paycheck",
        .freelancer: "Freelancer Monthly",
        .smallBusiness: "Small Business Monthly",
        .event: "Event Planning",
        .vacation: "Vacation",
        .businessTrip: "Business Trip",
        .empty: "Empty Budget",
    ] }
}

public enum BWShortcutMutation: String, AppEnum, CaseIterable, Codable, Hashable, Sendable {
    case create
    case update
    case delete

    public static var typeDisplayRepresentation: TypeDisplayRepresentation { TypeDisplayRepresentation(name: "Action") }
    public static var caseDisplayRepresentations: [BWShortcutMutation: DisplayRepresentation] { [
        .create: "Create",
        .update: "Update",
        .delete: "Delete",
    ] }
}

public struct BWShortcutBudget: AppEntity, Codable, Hashable, Sendable {
    public let id: UUID
    public let title: String

    public init(id: UUID, title: String) {
        self.id = id
        self.title = title
    }

    public static var typeDisplayRepresentation: TypeDisplayRepresentation { TypeDisplayRepresentation(name: "Budget") }
    public static var defaultQuery: BWShortcutBudgetQuery { BWShortcutBudgetQuery() }
    public var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(title)") }
}

public struct BWShortcutCategory: AppEntity, Codable, Hashable, Sendable {
    public let id: UUID
    public let budgetID: UUID
    public let budgetTitle: String
    public let currencyCode: String
    public let title: String
    public let categoryType: BWShortcutCategoryType
    public let plannedAmount: Int64
    public let actualAmount: Int64

    public init(id: UUID, budgetID: UUID, budgetTitle: String, currencyCode: String, title: String,
                categoryType: BWShortcutCategoryType, plannedAmount: Int64, actualAmount: Int64) {
        self.id = id
        self.budgetID = budgetID
        self.budgetTitle = budgetTitle
        self.currencyCode = currencyCode
        self.title = title
        self.categoryType = categoryType
        self.plannedAmount = plannedAmount
        self.actualAmount = actualAmount
    }

    public static var typeDisplayRepresentation: TypeDisplayRepresentation { TypeDisplayRepresentation(name: "Budget Category") }
    public static var defaultQuery: BWShortcutCategoryQuery { BWShortcutCategoryQuery() }
    public var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(title)",
            subtitle: "\(budgetTitle) · \(categoryType.rawValue.capitalized) · \(BWShortcutMoney.formatted(plannedAmount, currencyCode: currencyCode)) planned"
        )
    }
}

public struct BWShortcutTransaction: AppEntity, Codable, Hashable, Sendable {
    public let id: UUID
    public let budgetID: UUID
    public let budgetTitle: String
    public let currencyCode: String
    public let categoryID: UUID
    public let categoryTitle: String
    public let title: String
    public let details: String
    public let date: Date
    public let amount: Int64

    public init(id: UUID, budgetID: UUID, budgetTitle: String, currencyCode: String, categoryID: UUID,
                categoryTitle: String, title: String, details: String, date: Date, amount: Int64) {
        self.id = id
        self.budgetID = budgetID
        self.budgetTitle = budgetTitle
        self.currencyCode = currencyCode
        self.categoryID = categoryID
        self.categoryTitle = categoryTitle
        self.title = title
        self.details = details
        self.date = date
        self.amount = amount
    }

    public static var typeDisplayRepresentation: TypeDisplayRepresentation { TypeDisplayRepresentation(name: "Budget Transaction") }
    public static var defaultQuery: BWShortcutTransactionQuery { BWShortcutTransactionQuery() }
    public var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(title)",
            subtitle: "\(BWShortcutMoney.formatted(amount, currencyCode: currencyCode)) · \(categoryTitle) · \(budgetTitle)"
        )
    }
}

public struct BWShortcutReport: Sendable {
    public let budgetTitle: String
    public let currencyCode: String
    public let income: Int64
    public let plannedSpending: Int64
    public let actualSpending: Int64
    public let plannedSavings: Int64
    public let leftToBudget: Int64

    public init(budgetTitle: String, currencyCode: String, income: Int64,
                plannedSpending: Int64, actualSpending: Int64,
                plannedSavings: Int64, leftToBudget: Int64) {
        self.budgetTitle = budgetTitle
        self.currencyCode = currencyCode
        self.income = income
        self.plannedSpending = plannedSpending
        self.actualSpending = actualSpending
        self.plannedSavings = plannedSavings
        self.leftToBudget = leftToBudget
    }

    public var spokenSummary: String {
        return "\(budgetTitle): income \(BWShortcutMoney.formatted(income, currencyCode: currencyCode)); planned spending \(BWShortcutMoney.formatted(plannedSpending, currencyCode: currencyCode)); actual spending \(BWShortcutMoney.formatted(actualSpending, currencyCode: currencyCode)); planned savings \(BWShortcutMoney.formatted(plannedSavings, currencyCode: currencyCode)); left to budget \(BWShortcutMoney.formatted(leftToBudget, currencyCode: currencyCode))."
    }
}

public struct BWShortcutBudgetQuery: EntityStringQuery {
    @AppDependency(key: "BudgetWarden.IntentDataSource") private var source: any BWIntentDataSource
    public init() {}
    public func entities(for identifiers: [UUID]) async throws -> [BWShortcutBudget] {
        try await source.intentBudgets().filter { identifiers.contains($0.id) }
    }
    public func entities(matching string: String) async throws -> [BWShortcutBudget] {
        try await source.intentBudgets().filter { $0.title.localizedStandardContains(string) }
    }
    public func suggestedEntities() async throws -> [BWShortcutBudget] {
        try await source.intentBudgets()
    }
}

public struct BWShortcutCategoryQuery: EntityStringQuery {
    @AppDependency(key: "BudgetWarden.IntentDataSource") private var source: any BWIntentDataSource
    public init() {}
    public func entities(for identifiers: [UUID]) async throws -> [BWShortcutCategory] {
        try await source.intentCategories(budgetID: nil, categoryType: nil).filter { identifiers.contains($0.id) }
    }
    public func entities(matching string: String) async throws -> [BWShortcutCategory] {
        try await source.intentCategories(budgetID: nil, categoryType: nil).filter { $0.title.localizedStandardContains(string) || $0.budgetTitle.localizedStandardContains(string) }
    }
    public func suggestedEntities() async throws -> [BWShortcutCategory] {
        try await source.intentCategories(budgetID: nil, categoryType: nil)
    }
}

public struct BWShortcutTransactionQuery: EntityStringQuery {
    @AppDependency(key: "BudgetWarden.IntentDataSource") private var source: any BWIntentDataSource
    public init() {}
    public func entities(for identifiers: [UUID]) async throws -> [BWShortcutTransaction] {
        try await source.intentTransactions(budgetID: nil, categoryID: nil, search: nil, limit: Int.max)
            .filter { identifiers.contains($0.id) }
    }
    public func entities(matching string: String) async throws -> [BWShortcutTransaction] {
        try await source.intentTransactions(budgetID: nil, categoryID: nil, search: string, limit: 100)
    }
    public func suggestedEntities() async throws -> [BWShortcutTransaction] {
        try await source.intentTransactions(budgetID: nil, categoryID: nil, search: nil, limit: 50)
    }
}

@MainActor
private struct BWIntentSource {
    @AppDependency(key: "BudgetWarden.IntentDataSource") var value: any BWIntentDataSource
}

public struct BWListBudgetsIntent: AppIntent {
    public static var title: LocalizedStringResource { "List Budgets" }
    public static var description: IntentDescription { IntentDescription("Find budget files you have opened in Budget Warden.") }
    public static var openAppWhenRun: Bool { true }
    public init() {}
    @MainActor public func perform() async throws -> some ProvidesDialog & ReturnsValue<[BWShortcutBudget]> {
        let budgets = try await BWIntentSource().value.intentBudgets()
        return .result(value: budgets, dialog: "Found \(budgets.count) budgets.")
    }
}

public struct BWCreateBudgetIntent: AppIntent {
    public static var title: LocalizedStringResource { "Create Budget" }
    public static var description: IntentDescription { IntentDescription("Create a budget file from a built-in Budget Warden template.") }
    public static var openAppWhenRun: Bool { true }
    @Parameter(title: "Budget Name") public var title: String
    @Parameter(title: "Template") public var template: BWShortcutTemplate
    public init() {}
    @MainActor public func perform() async throws -> some ProvidesDialog & ReturnsValue<BWShortcutBudget> {
        let budget = try await BWIntentSource().value.intentCreateBudget(title: title, templateID: template.rawValue)
        return .result(value: budget, dialog: "Created \(budget.title).")
    }
}

public struct BWRenameBudgetIntent: AppIntent {
    public static var title: LocalizedStringResource { "Rename Budget" }
    public static var description: IntentDescription { IntentDescription("Change the title of a budget.") }
    public static var openAppWhenRun: Bool { true }
    @Parameter(title: "Budget") public var budget: BWShortcutBudget
    @Parameter(title: "New Name") public var newTitle: String
    public init() {}
    @MainActor public func perform() async throws -> some ProvidesDialog & ReturnsValue<BWShortcutBudget> {
        let updated = try await BWIntentSource().value.intentRenameBudget(id: budget.id, title: newTitle)
        return .result(value: updated, dialog: "Renamed the budget to \(updated.title).")
    }
}

public struct BWDeleteBudgetIntent: AppIntent {
    public static var title: LocalizedStringResource { "Delete Budget" }
    public static var description: IntentDescription { IntentDescription("Permanently delete a budget file.") }
    public static var openAppWhenRun: Bool { true }
    @Parameter(title: "Budget") public var budget: BWShortcutBudget
    public init() {}

    @MainActor public func perform() async throws -> some ProvidesDialog & ReturnsValue<BWShortcutBudget> {
        try await requestConfirmation(
            actionName: .custom(acceptLabel: "Delete", acceptAlternatives: [], denyLabel: "Cancel", denyAlternatives: [], destructive: true),
            dialog: IntentDialog("Permanently delete the budget \(budget.title) and its file?")
        )
        try await BWIntentSource().value.intentDeleteBudget(id: budget.id)
        return .result(value: budget, dialog: "Deleted the budget \(budget.title).")
    }
}

public struct BWBudgetSummaryIntent: AppIntent {
    public static var title: LocalizedStringResource { "Budget Summary" }
    public static var description: IntentDescription { IntentDescription("Read income, planned and actual spending, savings, and remaining budget.") }
    @Parameter(title: "Budget") public var budget: BWShortcutBudget
    public init() {}
    @MainActor public func perform() async throws -> some ProvidesDialog & ReturnsValue<String> {
        let report = try await BWIntentSource().value.intentReport(budgetID: budget.id)
        return .result(value: report.spokenSummary, dialog: "\(report.spokenSummary)")
    }
}

public struct BWListCategoriesIntent: AppIntent {
    public static var title: LocalizedStringResource { "List Budget Categories" }
    public static var description: IntentDescription { IntentDescription("Find categories in a budget, optionally filtered by type.") }
    @Parameter(title: "Budget") public var budget: BWShortcutBudget
    @Parameter(title: "Category Type") public var categoryType: BWShortcutCategoryType?
    public init() {}
    @MainActor public func perform() async throws -> some ProvidesDialog & ReturnsValue<[BWShortcutCategory]> {
        let categories = try await BWIntentSource().value.intentCategories(budgetID: budget.id, categoryType: categoryType)
        let summaries = categories.map {
            "\($0.title): \(BWShortcutMoney.formatted($0.actualAmount, currencyCode: $0.currencyCode)) actual of \(BWShortcutMoney.formatted($0.plannedAmount, currencyCode: $0.currencyCode)) planned"
        }.joined(separator: ". ")
        return .result(value: categories, dialog: categories.isEmpty ? "No matching categories." : "Categories: \(summaries).")
    }
}

public struct BWManageCategoryIntent: AppIntent {
    public static var title: LocalizedStringResource { "Manage Budget Category" }
    public static var description: IntentDescription { IntentDescription("Create, update, or delete a category. Deleting a category also removes its transactions.") }
    public static var openAppWhenRun: Bool { true }
    @Parameter(title: "Action") public var action: BWShortcutMutation
    @Parameter(title: "Budget") public var budget: BWShortcutBudget
    @Parameter(title: "Category") public var category: BWShortcutCategory?
    @Parameter(title: "Name") public var name: String?
    @Parameter(title: "Planned Amount", description: "Amount in your budget currency, with up to two decimal places") public var plannedAmount: Double?
    @Parameter(title: "Category Type") public var categoryType: BWShortcutCategoryType?
    public init() {}

    @MainActor public func perform() async throws -> some ProvidesDialog & ReturnsValue<BWShortcutCategory> {
        let source = BWIntentSource().value
        switch action {
        case .create:
            let name = if let name { name } else { try await $name.requestValue("What is the category name?") }
            let categoryType = if let categoryType { categoryType } else { try await $categoryType.requestValue("What type of category?") }
            let category = try await source.intentCreateCategory(
                budgetID: budget.id, title: name, plannedAmount: try BWIntentMoney.minorUnits(plannedAmount ?? 0), categoryType: categoryType
            )
            return .result(value: category, dialog: "Created the \(categoryType.rawValue) category \(category.title).")
        case .update:
            let category = if let category { category } else { try await $category.requestValue("Which category should I update?") }
            try validateBudget(category.budgetID, budget: budget)
            let name = if name == nil && plannedAmount == nil && categoryType == nil {
                try await $name.requestValue("What is the new category name?")
            } else { name }
            let amount = try plannedAmount.map(BWIntentMoney.minorUnits)
            let updated = try await source.intentUpdateCategory(
                id: category.id, budgetID: budget.id, title: name,
                plannedAmount: amount, categoryType: categoryType
            )
            return .result(value: updated, dialog: "Updated \(updated.title).")
        case .delete:
            let category = if let category { category } else { try await $category.requestValue("Which category should I delete?") }
            try validateBudget(category.budgetID, budget: budget)
            try await requestConfirmation(
                actionName: .custom(acceptLabel: "Delete", acceptAlternatives: [], denyLabel: "Cancel", denyAlternatives: [], destructive: true),
                dialog: IntentDialog("Delete \(category.title) and its transactions?")
            )
            try await source.intentDeleteCategory(id: category.id, budgetID: budget.id)
            return .result(value: category, dialog: "Deleted \(category.title) and its transactions.")
        }
    }
}

public struct BWCreateCategoryIntent: AppIntent {
    public static var title: LocalizedStringResource { "Create Budget Category" }
    public static var description: IntentDescription { IntentDescription("Add an income, expense, savings, or debt category to a budget.") }
    public static var openAppWhenRun: Bool { true }
    @Parameter(title: "Budget") public var budget: BWShortcutBudget
    @Parameter(title: "Name") public var name: String
    @Parameter(title: "Category Type") public var categoryType: BWShortcutCategoryType
    @Parameter(title: "Planned Amount", description: "Amount in your budget currency, with up to two decimal places") public var plannedAmount: Double?
    public init() {}

    @MainActor public func perform() async throws -> some ProvidesDialog & ReturnsValue<BWShortcutCategory> {
        let created = try await BWIntentSource().value.intentCreateCategory(
            budgetID: budget.id, title: name,
            plannedAmount: try BWIntentMoney.minorUnits(plannedAmount ?? 0), categoryType: categoryType
        )
        return .result(
            value: created,
            dialog: "Added \(created.title) to \(budget.title) with \(BWShortcutMoney.formatted(created.plannedAmount, currencyCode: created.currencyCode)) planned."
        )
    }
}

public struct BWListTransactionsIntent: AppIntent {
    public static var title: LocalizedStringResource { "List Budget Transactions" }
    public static var description: IntentDescription { IntentDescription("Find recent transactions, optionally filtered by category or search text.") }
    @Parameter(title: "Budget") public var budget: BWShortcutBudget
    @Parameter(title: "Category") public var category: BWShortcutCategory?
    @Parameter(title: "Search Text") public var searchText: String?
    @Parameter(title: "Maximum Results", default: 20) public var maximumResults: Int
    public init() {}
    @MainActor public func perform() async throws -> some ProvidesDialog & ReturnsValue<[BWShortcutTransaction]> {
        if let category { try validateBudget(category.budgetID, budget: budget) }
        let transactions = try await BWIntentSource().value.intentTransactions(
            budgetID: budget.id, categoryID: category?.id, search: searchText,
            limit: min(maximumResults, 100)
        )
        let names = transactions.map {
            "\($0.title), \(BWShortcutMoney.formatted($0.amount, currencyCode: $0.currencyCode)), in \($0.categoryTitle)"
        }.joined(separator: ". ")
        return .result(value: transactions, dialog: transactions.isEmpty ? "No matching transactions." : "\(names).")
    }
}

public struct BWManageTransactionIntent: AppIntent {
    public static var title: LocalizedStringResource { "Manage Budget Transaction" }
    public static var description: IntentDescription { IntentDescription("Create, update, or delete a transaction.") }
    public static var openAppWhenRun: Bool { true }
    @Parameter(title: "Action") public var action: BWShortcutMutation
    @Parameter(title: "Budget") public var budget: BWShortcutBudget
    @Parameter(title: "Transaction") public var transaction: BWShortcutTransaction?
    @Parameter(title: "Category") public var category: BWShortcutCategory?
    @Parameter(title: "Name") public var name: String?
    @Parameter(title: "Amount", description: "A non-negative amount in your budget currency, with up to two decimal places") public var amount: Double?
    @Parameter(title: "Date") public var date: Date?
    @Parameter(title: "Notes") public var details: String?
    public init() {}

    @MainActor public func perform() async throws -> some ProvidesDialog & ReturnsValue<BWShortcutTransaction> {
        let source = BWIntentSource().value
        if let category { try validateBudget(category.budgetID, budget: budget) }
        switch action {
        case .create:
            let category = if let category { category } else { try await $category.requestValue("Which category? A category from the selected budget is required.") }
            try validateBudget(category.budgetID, budget: budget)
            let name = if let name { name } else { try await $name.requestValue("What is the transaction name?") }
            let amount = if let amount { amount } else { try await $amount.requestValue("What is the amount?") }
            let created = try await source.intentCreateTransaction(
                budgetID: budget.id, categoryID: category.id, title: name,
                description: details, date: date ?? .now,
                amount: try BWIntentMoney.minorUnits(amount)
            )
            return .result(value: created, dialog: "Added \(created.title) to \(created.categoryTitle).")
        case .update:
            let transaction = if let transaction { transaction } else { try await $transaction.requestValue("Which transaction should I update?") }
            try validateBudget(transaction.budgetID, budget: budget)
            let name = if name == nil && details == nil && date == nil && amount == nil && category == nil {
                try await $name.requestValue("What is the new transaction name?")
            } else { name }
            let minorUnits = try amount.map(BWIntentMoney.minorUnits)
            let updated = try await source.intentUpdateTransaction(
                id: transaction.id, budgetID: budget.id, title: name,
                description: details, date: date, amount: minorUnits, categoryID: category?.id
            )
            return .result(value: updated, dialog: "Updated \(updated.title).")
        case .delete:
            let transaction = if let transaction { transaction } else { try await $transaction.requestValue("Which transaction should I delete?") }
            try validateBudget(transaction.budgetID, budget: budget)
            try await requestConfirmation(
                actionName: .custom(acceptLabel: "Delete", acceptAlternatives: [], denyLabel: "Cancel", denyAlternatives: [], destructive: true),
                dialog: IntentDialog("Delete the transaction \(transaction.title)?")
            )
            try await source.intentDeleteTransaction(id: transaction.id, budgetID: budget.id)
            return .result(value: transaction, dialog: "Deleted \(transaction.title).")
        }
    }
}

public struct BWCreateTransactionIntent: AppIntent {
    public static var title: LocalizedStringResource { "Create Budget Transaction" }
    public static var description: IntentDescription { IntentDescription("Add a transaction to a category in a budget.") }
    public static var openAppWhenRun: Bool { true }
    @Parameter(title: "Budget") public var budget: BWShortcutBudget
    @Parameter(title: "Category") public var category: BWShortcutCategory
    @Parameter(title: "Name") public var name: String
    @Parameter(title: "Amount", description: "A non-negative amount in your budget currency, with up to two decimal places") public var amount: Double
    @Parameter(title: "Date") public var date: Date?
    @Parameter(title: "Notes") public var details: String?
    public init() {}

    @MainActor public func perform() async throws -> some ProvidesDialog & ReturnsValue<BWShortcutTransaction> {
        try validateBudget(category.budgetID, budget: budget)
        let created = try await BWIntentSource().value.intentCreateTransaction(
            budgetID: budget.id, categoryID: category.id, title: name,
            description: details, date: date ?? .now, amount: try BWIntentMoney.minorUnits(amount)
        )
        return .result(
            value: created,
            dialog: "Added \(created.title), \(BWShortcutMoney.formatted(created.amount, currencyCode: created.currencyCode)), to \(created.categoryTitle)."
        )
    }
}

private enum BWIntentMoney {
    static func minorUnits(_ amount: Double) throws -> Int64 {
        guard amount.isFinite, amount >= 0,
              let decimal = Decimal(string: String(amount), locale: Locale(identifier: "en_US_POSIX")) else {
            throw BWIntentError("Enter a valid non-negative amount.")
        }
        let scaled = decimal * 100
        var rounded = Decimal()
        var input = scaled
        NSDecimalRound(&rounded, &input, 0, .plain)
        guard rounded == scaled, rounded <= Decimal(Int64.max) else {
            throw BWIntentError("Use no more than two decimal places and stay within the supported amount range.")
        }
        return NSDecimalNumber(decimal: rounded).int64Value
    }
}

private enum BWShortcutMoney {
    static func formatted(_ amount: Int64, currencyCode: String) -> String {
        let currency = BWCurrency(rawValue: currencyCode) ?? .defaultCurrency
        let magnitude = UInt64(clamping: amount.magnitude).formattedMoneyAmount(currency: currency)
        return amount < 0 ? "minus \(magnitude)" : magnitude
    }
}

private struct BWIntentError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private func validateBudget(_ entityBudgetID: UUID, budget: BWShortcutBudget) throws {
    guard entityBudgetID == budget.id else {
        throw BWIntentError("Choose a category or transaction from the selected budget.")
    }
}
