/*
 * Budget Warden
 * Copyright (c) 2026 Lazarov & Co EOOD
 * Author: Nikola Lazarov
 *
 * Licensed under the Source-Available Educational License.
 * See the LICENSE file in the project root for full terms.
 */

import AppIntents
import BWCore
import Foundation

private let intentServiceKey = "BudgetWarden.IntentService"

@MainActor
public enum BWIntentRegistration {
    /// Makes the app's budgets available to Siri and Shortcuts.
    public static func register(
        library: BWBudgetLibrary,
        googleDrive: BWGoogleDriveController,
        iCloud: BWICloudBudgetLibrary
    ) {
        let service = BWIntentBudgetService(library: library, googleDrive: googleDrive, iCloud: iCloud)
        AppDependencyManager.shared.add(key: intentServiceKey, dependency: service)
    }
}

// MARK: - Budget references

/// Identifies a budget for Shortcuts by where it is stored, so a budget can be
/// listed without reading it and resolved by reading only its own file.
enum BWBudgetReference: Hashable {
    /// A `.budget` file, by its standardized path.
    case file(String)
    /// A Google Drive budget, by its Drive file ID.
    case googleDrive(String)

    init?(_ id: String) {
        if id.hasPrefix("file:") {
            self = .file(String(id.dropFirst(5)))
        } else if id.hasPrefix("gdrive:") {
            self = .googleDrive(String(id.dropFirst(7)))
        } else {
            return nil
        }
    }

    init(_ url: URL) {
        self = .file(BWBudgetLibrary.location(url))
    }

    var id: String {
        switch self {
        case .file(let path): "file:\(path)"
        case .googleDrive(let id): "gdrive:\(id)"
        }
    }
}

/// The ID of a category or transaction: its UUID and its budget's reference.
struct BWBudgetItemID: Hashable {
    let itemID: UUID
    let budgetID: String

    init(itemID: UUID, budgetID: String) {
        self.itemID = itemID
        self.budgetID = budgetID
    }

    init?(_ id: String) {
        guard let separator = id.firstIndex(of: "@"),
              let itemID = UUID(uuidString: String(id[..<separator])) else {
            return nil
        }
        self.itemID = itemID
        budgetID = String(id[id.index(after: separator)...])
    }

    var id: String { "\(itemID.uuidString)@\(budgetID)" }
}

// MARK: - Service

/// Reads and changes budgets for App Intents through the shared
/// ``BWBudgetLibrary``. Changes are saved straight to the budget's file; the
/// app reloads the budget if it has it open, and never switches budgets.
@MainActor
public final class BWIntentBudgetService {
    private let library: BWBudgetLibrary
    private let googleDrive: BWGoogleDriveController
    private let iCloud: BWICloudBudgetLibrary

    init(library: BWBudgetLibrary, googleDrive: BWGoogleDriveController, iCloud: BWICloudBudgetLibrary) {
        self.library = library
        self.googleDrive = googleDrive
        self.iCloud = iCloud
    }

    // MARK: Budgets

    /// The open and recent budgets, iCloud Drive budgets, and Google Drive
    /// budgets. Reads only files that changed since they were last read, and
    /// never downloads.
    func budgets() -> [BWShortcutBudget] {
        var budgets: [BWShortcutBudget] = []
        var seen = Set<String>()
        func add(_ reference: BWBudgetReference, _ title: String) {
            if seen.insert(reference.id).inserted {
                budgets.append(BWShortcutBudget(id: reference.id, title: title))
            }
        }

        for url in library.knownURLs {
            if let driveID = googleDrive.budgetID(for: url) {
                let title = (try? library.budget(at: url).title)
                    ?? googleDrive.budget(withID: driveID)?.title
                    ?? Self.fileTitle(url)
                add(.googleDrive(driveID), title)
            } else if let cloud = iCloudBudget(at: url), !cloud.isDownloaded {
                add(BWBudgetReference(url), cloud.title)
            } else if let budget = try? library.budget(at: url) {
                add(BWBudgetReference(url), budget.title)
            }
        }
        for cloud in iCloud.budgets {
            let title = cloud.isDownloaded ? (try? library.budget(at: cloud.url).title) : nil
            add(BWBudgetReference(cloud.url), title ?? cloud.title)
        }
        if googleDrive.isSignedIn {
            for cloud in googleDrive.budgets {
                add(.googleDrive(cloud.id), cloud.title)
            }
        }
        return budgets
    }

    func createBudget(title: String, templateID: String) throws -> BWShortcutBudget {
        let title = try Self.nonEmpty(title, "Budget name")
        var budget = try budgetFromTemplateId(templateId: templateID, title: title)
        budget = try updateBudgetCurrency(budget: budget, currency: library.defaultCurrencyCode)
        let url = try library.create(budget, fileName: Self.fileName(for: title))
        return BWShortcutBudget(id: BWBudgetReference(url).id, title: budget.title)
    }

    func renameBudget(_ id: String, title: String) async throws -> BWShortcutBudget {
        let title = try Self.nonEmpty(title, "Budget name")
        let (budget, _) = try await mutate(id) { try updateBudgetTitle(budget: $0, title: title) }
        return BWShortcutBudget(id: id, title: budget.title)
    }

    func deleteBudget(_ id: String) async throws {
        guard case .file = BWBudgetReference(id) else {
            throw BWIntentError("Delete Google Drive budgets in Google Drive.")
        }
        try library.delete(at: try await url(for: id, writing: true))
    }

    func report(_ id: String) async throws -> BWShortcutReport {
        let budget = try await read(id)
        let totals = try buildReportingSummary(budget: budget).totals
        return BWShortcutReport(
            budgetTitle: budget.title,
            currencyCode: library.currencyCode(of: budget),
            income: totals.income.value,
            plannedSpending: totals.plannedSpending.value,
            actualSpending: totals.actualSpending.value,
            plannedSavings: totals.plannedSavings.value,
            leftToBudget: totals.leftToBudget
        )
    }

    // MARK: Categories

    /// Categories of one budget, or of every budget with a copy on this device.
    func categories(budgetID: String?, categoryType: BWShortcutCategoryType?) async throws -> [BWShortcutCategory] {
        try await loadedBudgets(budgetID).flatMap { id, budget in
            budget.orderedCategories(categoryType: categoryType?.coreValue).map {
                category($0, in: budget, budgetID: id)
            }
        }
    }

    func categories(withIDs ids: [String]) async throws -> [BWShortcutCategory] {
        try await items(withIDs: ids) { budgetID, budget, itemIDs in
            budget.categories.filter { itemIDs.contains($0.id) }.map { category($0, in: budget, budgetID: budgetID) }
        }
    }

    func createCategory(budgetID: String, title: String, plannedAmount: Int64, categoryType: BWShortcutCategoryType) async throws -> BWShortcutCategory {
        let title = try Self.nonEmpty(title, "Category name")
        let id = UUID()
        let (budget, _) = try await mutate(budgetID) { budget in
            let ordinal = budget.categories.filter { $0.categoryType == categoryType.coreValue }.count
            return try BWCore.createCategory(budget: budget, category: BWCategory(
                id: id, ordinal: Int32(ordinal), title: title,
                amountPlanned: BWMoneyAmount(value: plannedAmount), amountActual: BWMoneyAmount(value: 0),
                amountAccumulated: BWMoneyAmount(value: 0), categoryType: categoryType.coreValue, transactions: []
            ))
        }
        return try savedCategory(id, in: budget, budgetID: budgetID)
    }

    func updateCategory(_ id: String, title: String?, plannedAmount: Int64?, categoryType: BWShortcutCategoryType?) async throws -> BWShortcutCategory {
        let itemID = try Self.itemID(id)
        let title = try title.map { try Self.nonEmpty($0, "Category name") }
        let (budget, _) = try await mutate(itemID.budgetID) { budget in
            guard var category = budget.categories.first(where: { $0.id == itemID.itemID }) else {
                throw BWIntentError("That category is no longer in this budget.")
            }
            if let title { category.title = title }
            if let plannedAmount { category.amountPlanned = BWMoneyAmount(value: plannedAmount) }
            if let newType = categoryType?.coreValue, newType != category.categoryType {
                category.ordinal = Int32(budget.categories.filter { $0.categoryType == newType }.count)
                category.categoryType = newType
            }
            return try BWCore.updateCategory(budget: budget, category: category)
        }
        return try savedCategory(itemID.itemID, in: budget, budgetID: itemID.budgetID)
    }

    func deleteCategory(_ id: String) async throws {
        let itemID = try Self.itemID(id)
        _ = try await mutate(itemID.budgetID) { try BWCore.deleteCategory(budget: $0, categoryId: itemID.itemID) }
    }

    // MARK: Transactions

    /// Transactions of one budget, or of every budget with a copy on this
    /// device, newest first.
    func transactions(budgetID: String?, categoryID: String?, search: String?, limit: Int) async throws -> [BWShortcutTransaction] {
        let categoryUUID = try categoryID.map { try Self.itemID($0).itemID }
        let query = search?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let found = try await loadedBudgets(budgetID).flatMap { id, budget in
            budget.orderedCategories(categoryType: nil)
                .filter { categoryUUID == nil || $0.id == categoryUUID }
                .flatMap { category in
                    category.transactions
                        .filter {
                            query.isEmpty
                                || $0.title.localizedStandardContains(query)
                                || $0.description.localizedStandardContains(query)
                        }
                        .map { transaction($0, category: category, budget: budget, budgetID: id) }
                }
        }
        return Array(found.sorted { $0.date > $1.date }.prefix(max(limit, 0)))
    }

    func transactions(withIDs ids: [String]) async throws -> [BWShortcutTransaction] {
        try await items(withIDs: ids) { budgetID, budget, itemIDs in
            budget.categories.flatMap { category in
                category.transactions
                    .filter { itemIDs.contains($0.id) }
                    .map { transaction($0, category: category, budget: budget, budgetID: budgetID) }
            }
        }
    }

    func createTransaction(budgetID: String, categoryID: String, title: String, description: String?, date: Date, amount: Int64) async throws -> BWShortcutTransaction {
        let category = try Self.itemID(categoryID)
        try Self.requireSameBudget(category.budgetID, budgetID)
        let title = try Self.nonEmpty(title, "Transaction name")
        let created = try newTransaction(
            title: title, description: description, date: BWDate(date), amount: BWMoneyAmount(value: amount)
        )
        let (budget, _) = try await mutate(budgetID) {
            try BWCore.createTransaction(budget: $0, categoryId: category.itemID, transaction: created)
        }
        return try savedTransaction(created.id, in: budget, budgetID: budgetID)
    }

    func updateTransaction(_ id: String, title: String?, description: String?, date: Date?, amount: Int64?, categoryID: String?) async throws -> BWShortcutTransaction {
        let itemID = try Self.itemID(id)
        let destination = try categoryID.map { try Self.itemID($0) }
        if let destination { try Self.requireSameBudget(destination.budgetID, itemID.budgetID) }
        let title = try title.map { try Self.nonEmpty($0, "Transaction name") }
        let (budget, _) = try await mutate(itemID.budgetID) { budget in
            guard let source = budget.categories.first(where: { $0.transactions.contains { $0.id == itemID.itemID } }),
                  var changed = source.transactions.first(where: { $0.id == itemID.itemID }) else {
                throw BWIntentError("That transaction is no longer in this budget.")
            }
            if let title { changed.title = title }
            if let description { changed.description = description }
            if let date { changed.date = BWDate(date) }
            if let amount { changed.amount = BWMoneyAmount(value: amount) }
            var updated = try BWCore.updateTransaction(budget: budget, categoryId: source.id, transaction: changed)
            if let target = destination?.itemID, target != source.id {
                guard budget.categories.contains(where: { $0.id == target }) else {
                    throw BWIntentError("Choose a category from this budget.")
                }
                updated = try moveTransaction(
                    budget: updated, originCategoryId: source.id, targetCategoryId: target, transactionId: itemID.itemID
                )
            }
            return updated
        }
        return try savedTransaction(itemID.itemID, in: budget, budgetID: itemID.budgetID)
    }

    func deleteTransaction(_ id: String) async throws {
        let itemID = try Self.itemID(id)
        _ = try await mutate(itemID.budgetID) { budget in
            guard let category = budget.categories.first(where: { $0.transactions.contains { $0.id == itemID.itemID } }) else {
                throw BWIntentError("That transaction is no longer in this budget.")
            }
            return try BWCore.deleteTransaction(budget: budget, categoryId: category.id, transactionId: itemID.itemID)
        }
    }

    // MARK: Storage

    /// The file that holds a budget, downloading it first when needed.
    private func url(for id: String, writing: Bool) async throws -> URL {
        switch BWBudgetReference(id) {
        case .googleDrive(let driveID):
            guard let cloud = googleDrive.budget(withID: driveID) else {
                throw BWIntentError("That Google Drive budget is not available. Sign in to Google Drive in Budget Warden.")
            }
            if writing && !cloud.canEdit {
                throw BWIntentError("\(cloud.title) is view only.")
            }
            if let path = cloud.localPath, FileManager.default.fileExists(atPath: path) {
                return URL(fileURLWithPath: path)
            }
            return try await googleDrive.open(cloud)
        case .file(let path):
            let cloud = iCloud.budgets.first { BWBudgetLibrary.location($0.url) == path }
            guard let url = library.knownURL(location: path) ?? cloud?.url else {
                throw BWIntentError("That budget is no longer available. Open it in Budget Warden first.")
            }
            if writing, cloud?.isReadOnly == true {
                throw BWIntentError("\(cloud?.title ?? "That budget") is view only.")
            }
            if iCloud.contains(url) {
                try await iCloud.prepareForOpening(url)
            }
            return url
        case nil:
            throw BWIntentError("Choose the budget again in Shortcuts.")
        }
    }

    /// The file of a budget that already has a copy on this device, without
    /// downloading it.
    private func localURL(for id: String) -> URL? {
        switch BWBudgetReference(id) {
        case .googleDrive(let driveID):
            guard let path = googleDrive.budget(withID: driveID)?.localPath,
                  FileManager.default.fileExists(atPath: path) else { return nil }
            return URL(fileURLWithPath: path)
        case .file(let path):
            if let cloud = iCloud.budgets.first(where: { BWBudgetLibrary.location($0.url) == path }) {
                return cloud.isDownloaded ? cloud.url : nil
            }
            return library.knownURL(location: path)
        case nil:
            return nil
        }
    }

    private func read(_ id: String) async throws -> BWBudget {
        try library.budget(at: try await url(for: id, writing: false))
    }

    /// One budget, or every budget with a copy on this device. Listing
    /// across budgets never downloads, so it stays fast with many budgets.
    private func loadedBudgets(_ budgetID: String?) async throws -> [(String, BWBudget)] {
        if let budgetID {
            return [(budgetID, try await read(budgetID))]
        }
        return budgets().compactMap { entry in
            guard let url = localURL(for: entry.id), let budget = try? library.budget(at: url) else { return nil }
            return (entry.id, budget)
        }
    }

    /// Resolves item IDs by reading each referenced budget once.
    private func items<Item>(
        withIDs ids: [String],
        _ select: (String, BWBudget, Set<UUID>) -> [Item]
    ) async throws -> [Item] {
        var byBudget: [String: Set<UUID>] = [:]
        for itemID in ids.compactMap(BWBudgetItemID.init) {
            byBudget[itemID.budgetID, default: []].insert(itemID.itemID)
        }
        var found: [Item] = []
        for (budgetID, itemIDs) in byBudget {
            guard let budget = try? await read(budgetID) else { continue }
            found += select(budgetID, budget, itemIDs)
        }
        return found
    }

    private func mutate(_ id: String, _ operation: (BWBudget) throws -> BWBudget) async throws -> (BWBudget, URL) {
        let url = try await url(for: id, writing: true)
        return (try library.mutate(at: url, operation), url)
    }

    private func iCloudBudget(at url: URL) -> BWICloudBudget? {
        let location = BWBudgetLibrary.location(url)
        return iCloud.budgets.first { BWBudgetLibrary.location($0.url) == location }
    }

    // MARK: Entities

    private func category(_ category: BWCategory, in budget: BWBudget, budgetID: String) -> BWShortcutCategory {
        BWShortcutCategory(
            id: BWBudgetItemID(itemID: category.id, budgetID: budgetID).id,
            budgetID: budgetID, budgetTitle: budget.title, currencyCode: library.currencyCode(of: budget),
            title: category.title, categoryType: BWShortcutCategoryType(category.categoryType),
            plannedAmount: category.amountPlanned.value, actualAmount: category.amountActual.value
        )
    }

    private func transaction(_ transaction: BWTransaction, category: BWCategory, budget: BWBudget, budgetID: String) -> BWShortcutTransaction {
        BWShortcutTransaction(
            id: BWBudgetItemID(itemID: transaction.id, budgetID: budgetID).id,
            budgetID: budgetID, budgetTitle: budget.title, currencyCode: library.currencyCode(of: budget),
            categoryID: BWBudgetItemID(itemID: category.id, budgetID: budgetID).id,
            categoryTitle: category.title, title: transaction.title, details: transaction.description,
            date: transaction.date.foundationDate, amount: transaction.amount.value
        )
    }

    private func savedCategory(_ id: UUID, in budget: BWBudget, budgetID: String) throws -> BWShortcutCategory {
        guard let saved = budget.categories.first(where: { $0.id == id }) else {
            throw BWIntentError("The category could not be found after saving.")
        }
        return category(saved, in: budget, budgetID: budgetID)
    }

    private func savedTransaction(_ id: UUID, in budget: BWBudget, budgetID: String) throws -> BWShortcutTransaction {
        for category in budget.categories {
            if let saved = category.transactions.first(where: { $0.id == id }) {
                return transaction(saved, category: category, budget: budget, budgetID: budgetID)
            }
        }
        throw BWIntentError("The transaction could not be found after saving.")
    }

    // MARK: Helpers

    private static func itemID(_ id: String) throws -> BWBudgetItemID {
        guard let itemID = BWBudgetItemID(id) else {
            throw BWIntentError("Choose the category or transaction again in Shortcuts.")
        }
        return itemID
    }

    private static func requireSameBudget(_ itemBudgetID: String, _ budgetID: String) throws {
        guard itemBudgetID == budgetID else {
            throw BWIntentError("Choose a category or transaction from the selected budget.")
        }
    }

    private static func nonEmpty(_ value: String, _ name: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw BWIntentError("\(name) cannot be empty.") }
        return trimmed
    }

    static func fileName(for title: String) -> String {
        let safe = title.components(separatedBy: CharacterSet(charactersIn: "/:")).joined(separator: "-")
        return safe.hasSuffix(".budget") ? safe : "\(safe).budget"
    }

    private static func fileTitle(_ url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
    }
}

// MARK: - Entities

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
    case freelancer = "freelancer-monthly"
    case smallBusiness = "small-business-monthly"
    case vacation
    case empty

    public static var typeDisplayRepresentation: TypeDisplayRepresentation { TypeDisplayRepresentation(name: "Budget Template") }
    public static var caseDisplayRepresentations: [BWShortcutTemplate: DisplayRepresentation] { [
        .monthly: "Personal Monthly Budget",
        .weekly: "Personal Weekly Budget",
        .freelancer: "Freelancer Monthly Budget",
        .smallBusiness: "Small Business Monthly Budget",
        .vacation: "Trip Budget",
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

/// A budget, identified by where it is stored (see ``BWBudgetReference``).
public struct BWShortcutBudget: AppEntity, Codable, Hashable, Sendable {
    public let id: String
    public let title: String

    public init(id: String, title: String) {
        self.id = id
        self.title = title
    }

    public static var typeDisplayRepresentation: TypeDisplayRepresentation { TypeDisplayRepresentation(name: "Budget") }
    public static var defaultQuery: BWShortcutBudgetQuery { BWShortcutBudgetQuery() }
    public var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(title)") }
}

/// A category. Its ID includes its budget's, so it resolves from one file.
public struct BWShortcutCategory: AppEntity, Codable, Hashable, Sendable {
    public let id: String
    public let budgetID: String
    public let budgetTitle: String
    public let currencyCode: String
    public let title: String
    public let categoryType: BWShortcutCategoryType
    public let plannedAmount: Int64
    public let actualAmount: Int64

    public init(id: String, budgetID: String, budgetTitle: String, currencyCode: String, title: String,
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

/// A transaction. Its ID includes its budget's, so it resolves from one file.
public struct BWShortcutTransaction: AppEntity, Codable, Hashable, Sendable {
    public let id: String
    public let budgetID: String
    public let budgetTitle: String
    public let currencyCode: String
    public let categoryID: String
    public let categoryTitle: String
    public let title: String
    public let details: String
    public let date: Date
    public let amount: Int64

    public init(id: String, budgetID: String, budgetTitle: String, currencyCode: String, categoryID: String,
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

    public var spokenSummary: String {
        let money = { (amount: Int64) in BWShortcutMoney.formatted(amount, currencyCode: currencyCode) }
        return "\(budgetTitle): income \(money(income)); planned spending \(money(plannedSpending)); actual spending \(money(actualSpending)); planned savings \(money(plannedSavings)); left to budget \(money(leftToBudget))."
    }
}

// MARK: - Queries

public struct BWShortcutBudgetQuery: EntityStringQuery {
    @AppDependency(key: "BudgetWarden.IntentService") private var service: BWIntentBudgetService
    public init() {}
    public func entities(for identifiers: [String]) async throws -> [BWShortcutBudget] {
        let wanted = Set(identifiers)
        return await service.budgets().filter { wanted.contains($0.id) }
    }
    public func entities(matching string: String) async throws -> [BWShortcutBudget] {
        await service.budgets().filter { $0.title.localizedStandardContains(string) }
    }
    public func suggestedEntities() async throws -> [BWShortcutBudget] {
        await service.budgets()
    }
}

public struct BWShortcutCategoryQuery: EntityStringQuery {
    @AppDependency(key: "BudgetWarden.IntentService") private var service: BWIntentBudgetService
    public init() {}
    public func entities(for identifiers: [String]) async throws -> [BWShortcutCategory] {
        try await service.categories(withIDs: identifiers)
    }
    public func entities(matching string: String) async throws -> [BWShortcutCategory] {
        try await service.categories(budgetID: nil, categoryType: nil).filter {
            $0.title.localizedStandardContains(string) || $0.budgetTitle.localizedStandardContains(string)
        }
    }
    public func suggestedEntities() async throws -> [BWShortcutCategory] {
        try await service.categories(budgetID: nil, categoryType: nil)
    }
}

public struct BWShortcutTransactionQuery: EntityStringQuery {
    @AppDependency(key: "BudgetWarden.IntentService") private var service: BWIntentBudgetService
    public init() {}
    public func entities(for identifiers: [String]) async throws -> [BWShortcutTransaction] {
        try await service.transactions(withIDs: identifiers)
    }
    public func entities(matching string: String) async throws -> [BWShortcutTransaction] {
        try await service.transactions(budgetID: nil, categoryID: nil, search: string, limit: 100)
    }
    public func suggestedEntities() async throws -> [BWShortcutTransaction] {
        try await service.transactions(budgetID: nil, categoryID: nil, search: nil, limit: 50)
    }
}

@MainActor
private struct BWIntentSource {
    @AppDependency(key: "BudgetWarden.IntentService") var value: BWIntentBudgetService
}

// MARK: - Intents

public struct BWListBudgetsIntent: AppIntent {
    public static var title: LocalizedStringResource { "List Budgets" }
    public static var description: IntentDescription { IntentDescription("Find your recent, iCloud Drive, and Google Drive budgets.") }
    public static var openAppWhenRun: Bool { true }
    public init() {}
    @MainActor public func perform() async throws -> some ProvidesDialog & ReturnsValue<[BWShortcutBudget]> {
        let budgets = BWIntentSource().value.budgets()
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
        let budget = try BWIntentSource().value.createBudget(title: title, templateID: template.rawValue)
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
        let updated = try await BWIntentSource().value.renameBudget(budget.id, title: newTitle)
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
        try await BWIntentSource().value.deleteBudget(budget.id)
        return .result(value: budget, dialog: "Deleted the budget \(budget.title).")
    }
}

public struct BWBudgetSummaryIntent: AppIntent {
    public static var title: LocalizedStringResource { "Budget Summary" }
    public static var description: IntentDescription { IntentDescription("Read income, planned and actual spending, savings, and remaining budget.") }
    @Parameter(title: "Budget") public var budget: BWShortcutBudget
    public init() {}
    @MainActor public func perform() async throws -> some ProvidesDialog & ReturnsValue<String> {
        let report = try await BWIntentSource().value.report(budget.id)
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
        let categories = try await BWIntentSource().value.categories(budgetID: budget.id, categoryType: categoryType)
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
    @Parameter(title: "Planned Amount", description: "Amount in the budget's currency, with up to two decimal places") public var plannedAmount: Double?
    @Parameter(title: "Category Type") public var categoryType: BWShortcutCategoryType?
    public init() {}

    @MainActor public func perform() async throws -> some ProvidesDialog & ReturnsValue<BWShortcutCategory> {
        let service = BWIntentSource().value
        switch action {
        case .create:
            let name = if let name { name } else { try await $name.requestValue("What is the category name?") }
            let categoryType = if let categoryType { categoryType } else { try await $categoryType.requestValue("What type of category?") }
            let category = try await service.createCategory(
                budgetID: budget.id, title: name, plannedAmount: try BWIntentMoney.minorUnits(plannedAmount ?? 0), categoryType: categoryType
            )
            return .result(value: category, dialog: "Created the \(categoryType.rawValue) category \(category.title).")
        case .update:
            let category = if let category { category } else { try await $category.requestValue("Which category should I update?") }
            try validateBudget(category.budgetID, budget: budget)
            let name = if name == nil && plannedAmount == nil && categoryType == nil {
                try await $name.requestValue("What is the new category name?")
            } else { name }
            let updated = try await service.updateCategory(
                category.id, title: name, plannedAmount: try plannedAmount.map(BWIntentMoney.minorUnits), categoryType: categoryType
            )
            return .result(value: updated, dialog: "Updated \(updated.title).")
        case .delete:
            let category = if let category { category } else { try await $category.requestValue("Which category should I delete?") }
            try validateBudget(category.budgetID, budget: budget)
            try await requestConfirmation(
                actionName: .custom(acceptLabel: "Delete", acceptAlternatives: [], denyLabel: "Cancel", denyAlternatives: [], destructive: true),
                dialog: IntentDialog("Delete \(category.title) and its transactions?")
            )
            try await service.deleteCategory(category.id)
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
    @Parameter(title: "Planned Amount", description: "Amount in the budget's currency, with up to two decimal places") public var plannedAmount: Double?
    public init() {}

    @MainActor public func perform() async throws -> some ProvidesDialog & ReturnsValue<BWShortcutCategory> {
        let created = try await BWIntentSource().value.createCategory(
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
        let transactions = try await BWIntentSource().value.transactions(
            budgetID: budget.id, categoryID: category?.id, search: searchText, limit: min(maximumResults, 100)
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
    @Parameter(title: "Amount", description: "A non-negative amount in the budget's currency, with up to two decimal places") public var amount: Double?
    @Parameter(title: "Date") public var date: Date?
    @Parameter(title: "Notes") public var details: String?
    public init() {}

    @MainActor public func perform() async throws -> some ProvidesDialog & ReturnsValue<BWShortcutTransaction> {
        let service = BWIntentSource().value
        if let category { try validateBudget(category.budgetID, budget: budget) }
        switch action {
        case .create:
            let category = if let category { category } else { try await $category.requestValue("Which category? A category from the selected budget is required.") }
            try validateBudget(category.budgetID, budget: budget)
            let name = if let name { name } else { try await $name.requestValue("What is the transaction name?") }
            let amount = if let amount { amount } else { try await $amount.requestValue("What is the amount?") }
            let created = try await service.createTransaction(
                budgetID: budget.id, categoryID: category.id, title: name,
                description: details, date: date ?? .now, amount: try BWIntentMoney.minorUnits(amount)
            )
            return .result(value: created, dialog: "Added \(created.title) to \(created.categoryTitle).")
        case .update:
            let transaction = if let transaction { transaction } else { try await $transaction.requestValue("Which transaction should I update?") }
            try validateBudget(transaction.budgetID, budget: budget)
            let name = if name == nil && details == nil && date == nil && amount == nil && category == nil {
                try await $name.requestValue("What is the new transaction name?")
            } else { name }
            let updated = try await service.updateTransaction(
                transaction.id, title: name, description: details, date: date,
                amount: try amount.map(BWIntentMoney.minorUnits), categoryID: category?.id
            )
            return .result(value: updated, dialog: "Updated \(updated.title).")
        case .delete:
            let transaction = if let transaction { transaction } else { try await $transaction.requestValue("Which transaction should I delete?") }
            try validateBudget(transaction.budgetID, budget: budget)
            try await requestConfirmation(
                actionName: .custom(acceptLabel: "Delete", acceptAlternatives: [], denyLabel: "Cancel", denyAlternatives: [], destructive: true),
                dialog: IntentDialog("Delete the transaction \(transaction.title)?")
            )
            try await service.deleteTransaction(transaction.id)
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
    @Parameter(title: "Amount", description: "A non-negative amount in the budget's currency, with up to two decimal places") public var amount: Double
    @Parameter(title: "Date") public var date: Date?
    @Parameter(title: "Notes") public var details: String?
    public init() {}

    @MainActor public func perform() async throws -> some ProvidesDialog & ReturnsValue<BWShortcutTransaction> {
        try validateBudget(category.budgetID, budget: budget)
        let created = try await BWIntentSource().value.createTransaction(
            budgetID: budget.id, categoryID: category.id, title: name,
            description: details, date: date ?? .now, amount: try BWIntentMoney.minorUnits(amount)
        )
        return .result(
            value: created,
            dialog: "Added \(created.title), \(BWShortcutMoney.formatted(created.amount, currencyCode: created.currencyCode)), to \(created.categoryTitle)."
        )
    }
}

// MARK: - Helpers

enum BWIntentMoney {
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

struct BWIntentError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private func validateBudget(_ entityBudgetID: String, budget: BWShortcutBudget) throws {
    guard entityBudgetID == budget.id else {
        throw BWIntentError("Choose a category or transaction from the selected budget.")
    }
}
