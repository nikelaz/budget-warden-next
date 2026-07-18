/*
 * Budget Warden
 * Copyright (c) 2026 Lazarov & Co EOOD
 * Author: Nikola Lazarov
 *
 * Licensed under the Source-Available Educational License.
 * See the LICENSE file in the project root for full terms.
 */

import Foundation
import BWCore

extension BWBudget: @retroactive Identifiable {}
extension BWCategory: @retroactive Identifiable {}
extension BWTransaction: @retroactive Identifiable {}

enum BWError: LocalizedError {
    case readingFile(Error? = nil)
    case decodingFile(Error? = nil)
    case savingFile(Error? = nil)
    case creatingBudget(Error? = nil)
    case removingRecentItem(Error? = nil)
    case core(String)
    case validation(String)

    var errorDescription: String? {
        switch self {
        case .readingFile:
            return "Could not read the budget file."
        case .decodingFile:
            return "The selected file is not a valid Budget Warden budget."
        case .savingFile:
            return "Could not save the budget file."
        case .creatingBudget:
            return "Could not create the budget."
        case .removingRecentItem:
            return "Could not remove the item from Recents."
        case .core(let message), .validation(let message):
            return message
        }
    }
}

struct BWCurrency: RawRepresentable, CaseIterable, Hashable, Sendable {
    let rawValue: String

    static let allCases = Locale.Currency.isoCurrencies
        .map { BWCurrency(uncheckedRawValue: $0.identifier) }
        .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }

    static var defaultCurrency: BWCurrency {
        Locale.current.currency
            .flatMap { BWCurrency(rawValue: $0.identifier) }
            ?? BWCurrency(uncheckedRawValue: "USD")
    }

    init?(rawValue: String) {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard Locale.Currency.isoCurrencies.contains(where: { $0.identifier == value }) else { return nil }
        self.rawValue = value
    }

    private init(uncheckedRawValue: String) {
        rawValue = uncheckedRawValue
    }

    var symbol: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = rawValue
        return formatter.currencySymbol ?? rawValue
    }

    var displayName: String {
        let title = Locale.current.localizedString(forCurrencyCode: rawValue) ?? rawValue
        return "\(title) (\(rawValue), \(symbol))"
    }
}

extension BWCategoryType {
    var title: String {
        switch self {
        case .income: "Income"
        case .expenses: "Expenses"
        case .savings: "Savings"
        case .debt: "Debt"
        }
    }
}

extension BWBudget {
    func orderedCategories(for type: BWCategoryType? = nil) -> [BWCategory] {
        categories
            .filter { type == nil || $0.categoryType == type }
            .sorted { ($0.categoryType.rawValue, $0.ordinal) < ($1.categoryType.rawValue, $1.ordinal) }
    }
}

extension BWDate {
    init(_ date: Date, calendar: Calendar = .current) {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(
            year: Int32(components.year ?? 1970),
            month: Int32(components.month ?? 1),
            day: Int32(components.day ?? 1)
        )
    }

    var foundationDate: Date {
        Calendar.current.date(from: DateComponents(
            year: Int(year),
            month: Int(month),
            day: Int(day)
        )) ?? .distantPast
    }
}

extension BWDate: @retroactive Comparable {
    public static func < (lhs: BWDate, rhs: BWDate) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }
}

extension BWMoneyAmount: @retroactive Comparable {
    public static func < (lhs: BWMoneyAmount, rhs: BWMoneyAmount) -> Bool {
        lhs.value < rhs.value
    }

    var unsignedValue: UInt64 {
        UInt64(clamping: value)
    }

    var moneyInputText: String {
        unsignedValue.moneyInputText
    }

    func formattedMoneyAmount(currency: BWCurrency) -> String {
        unsignedValue.formattedMoneyAmount(currency: currency)
    }
}

extension UInt64 {
    var moneyInputText: String {
        String(format: "%llu.%02llu", self / 100, self % 100)
    }

    func formattedMoneyAmount(currency: BWCurrency) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currency.rawValue
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSDecimalNumber(value: Double(self) / 100))
            ?? "\(moneyInputText) \(currency.symbol)"
    }

    static func parseMoneyAmount(_ text: String, emptyValue: UInt64? = nil) -> UInt64? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return emptyValue }
        let parts = value.replacingOccurrences(of: ",", with: ".")
            .split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count <= 2,
              parts[0].allSatisfy(\.isNumber),
              parts.count == 1 || ((1...2).contains(parts[1].count) && parts[1].allSatisfy(\.isNumber)),
              let whole = UInt64(parts[0].isEmpty ? "0" : parts[0])
        else { return nil }

        let wholeResult = whole.multipliedReportingOverflow(by: 100)
        guard !wholeResult.overflow else { return nil }
        let fraction = parts.count == 2 ? UInt64(parts[1]) ?? 0 : 0
        let minor = parts.count == 2 && parts[1].count == 1 ? fraction * 10 : fraction
        let result = wholeResult.partialValue.addingReportingOverflow(minor)
        return result.overflow ? nil : result.partialValue
    }

    static func sumMoneyAmounts(_ amounts: some Sequence<UInt64>) -> UInt64? {
        amounts.reduce(into: Optional<UInt64>(0)) { total, amount in
            guard let current = total else { return }
            let result = current.addingReportingOverflow(amount)
            total = result.overflow ? nil : result.partialValue
        }
    }
}

enum BWReportingAmountMode: String, CaseIterable, Identifiable {
    case planned
    case actual
    var id: Self { self }
    var title: String { self == .planned ? "Planned" : "Actual" }
    func amount(in category: BWCategory) -> UInt64 {
        (self == .planned ? category.amountPlanned : category.amountActual).unsignedValue
    }
}

struct BWReportingAmountSegment: Identifiable {
    let title: String
    let amount: UInt64
    var id: String { title }
}

struct BWReportingComparisonAmountSegment: Identifiable {
    let rowTitle: String
    let componentTitle: String
    let amount: UInt64
    var id: String { "\(rowTitle)-\(componentTitle)" }
}

struct BWReportingComparisonTotal: Identifiable {
    let title: String
    let amount: UInt64
    var id: String { title }
}

enum BWReportingSummary {
    static func total(in budget: BWBudget, for types: Set<BWCategoryType>, amount: (BWCategory) -> UInt64) -> UInt64 {
        UInt64.sumMoneyAmounts(budget.categories.filter { types.contains($0.categoryType) }.map(amount)) ?? .max
    }

    static func incomeTotal(in budget: BWBudget) -> UInt64 { total(in: budget, for: [.income]) { $0.amountPlanned.unsignedValue } }
    static func plannedSpendingTotal(in budget: BWBudget) -> UInt64 { total(in: budget, for: [.expenses, .debt]) { $0.amountPlanned.unsignedValue } }
    static func actualSpendingTotal(in budget: BWBudget) -> UInt64 { total(in: budget, for: [.expenses, .debt]) { $0.amountActual.unsignedValue } }
    static func plannedSavingsTotal(in budget: BWBudget) -> UInt64 { total(in: budget, for: [.savings]) { $0.amountPlanned.unsignedValue } }

    static func leftToBudgetTotal(in budget: BWBudget) -> Int64? {
        guard let income = Int64(exactly: incomeTotal(in: budget)),
              let spending = Int64(exactly: plannedSpendingTotal(in: budget)),
              let savings = Int64(exactly: plannedSavingsTotal(in: budget)) else { return nil }
        return income - spending - savings
    }

    static func allocationSegments(in budget: BWBudget, amountMode: BWReportingAmountMode) -> [BWReportingAmountSegment] {
        [("Expenses", BWCategoryType.expenses), ("Savings", .savings), ("Debt", .debt)]
            .map { BWReportingAmountSegment(title: $0.0, amount: total(in: budget, for: [$0.1], amount: amountMode.amount)) }
            .filter { $0.amount > 0 }
    }

    static func categorySegments(in budget: BWBudget, categoryType: BWCategoryType, amountMode: BWReportingAmountMode) -> [BWReportingAmountSegment] {
        budget.orderedCategories(for: categoryType)
            .map { BWReportingAmountSegment(title: $0.title, amount: amountMode.amount(in: $0)) }
            .filter { $0.amount > 0 }
    }

    static func incomeVsAllocationSegments(in budget: BWBudget, plannedRowTitle: String, actualRowTitle: String) -> [BWReportingComparisonAmountSegment] {
        [
            BWReportingComparisonAmountSegment(rowTitle: "Income", componentTitle: "Income", amount: incomeTotal(in: budget)),
            BWReportingComparisonAmountSegment(rowTitle: plannedRowTitle, componentTitle: "Expenses", amount: total(in: budget, for: [.expenses]) { $0.amountPlanned.unsignedValue }),
            BWReportingComparisonAmountSegment(rowTitle: plannedRowTitle, componentTitle: "Savings", amount: total(in: budget, for: [.savings]) { $0.amountPlanned.unsignedValue }),
            BWReportingComparisonAmountSegment(rowTitle: plannedRowTitle, componentTitle: "Debt", amount: total(in: budget, for: [.debt]) { $0.amountPlanned.unsignedValue }),
            BWReportingComparisonAmountSegment(rowTitle: actualRowTitle, componentTitle: "Expenses", amount: total(in: budget, for: [.expenses]) { $0.amountActual.unsignedValue }),
            BWReportingComparisonAmountSegment(rowTitle: actualRowTitle, componentTitle: "Savings", amount: total(in: budget, for: [.savings]) { $0.amountActual.unsignedValue }),
            BWReportingComparisonAmountSegment(rowTitle: actualRowTitle, componentTitle: "Debt", amount: total(in: budget, for: [.debt]) { $0.amountActual.unsignedValue })
        ].filter { $0.amount > 0 }
    }

    static func incomeVsAllocationTotals(in budget: BWBudget) -> [BWReportingComparisonTotal] {
        let outflows: Set<BWCategoryType> = [.expenses, .savings, .debt]
        return [
            BWReportingComparisonTotal(title: "Income", amount: incomeTotal(in: budget)),
            BWReportingComparisonTotal(title: "Planned", amount: total(in: budget, for: outflows) { $0.amountPlanned.unsignedValue }),
            BWReportingComparisonTotal(title: "Actual", amount: total(in: budget, for: outflows) { $0.amountActual.unsignedValue })
        ]
    }
}
