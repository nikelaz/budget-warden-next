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

public enum BWReportingAmountMode: String, CaseIterable, Identifiable, Sendable {
    case planned
    case actual

    public var id: Self {
        self
    }

    public var title: String {
        switch self {
            case .planned:
                return "Planned"
            case .actual:
                return "Actual"
        }
    }

    public var amountKeyPath: KeyPath<BWCategory, UInt64> {
        switch self {
            case .planned:
                return \.amountPlanned
            case .actual:
                return \.amountActual
        }
    }
}

public struct BWReportingAmountSegment: Identifiable, Sendable {
    public let title: String
    public let amount: UInt64

    public var id: String {
        title
    }

    public init(title: String, amount: UInt64) {
        self.title = title
        self.amount = amount
    }
}

public struct BWReportingComparisonAmountSegment: Identifiable, Sendable {
    public let rowTitle: String
    public let componentTitle: String
    public let amount: UInt64

    public var id: String {
        "\(rowTitle)-\(componentTitle)"
    }

    public init(rowTitle: String, componentTitle: String, amount: UInt64) {
        self.rowTitle = rowTitle
        self.componentTitle = componentTitle
        self.amount = amount
    }
}

public struct BWReportingComparisonTotal: Identifiable, Sendable {
    public let title: String
    public let amount: UInt64

    public var id: String {
        title
    }

    public init(title: String, amount: UInt64) {
        self.title = title
        self.amount = amount
    }
}

public enum BWReportingSummary {
    public static func total(
        in budget: BWBudget,
        for types: Set<BWCategoryType>,
        amount: KeyPath<BWCategory, UInt64>
    ) -> UInt64 {
        UInt64.sumMoneyAmounts(
            budget.categories
                .filter { types.contains($0.categoryType) }
                .map { $0[keyPath: amount] }
        ) ?? UInt64.max
    }

    public static func incomeTotal(in budget: BWBudget) -> UInt64 {
        total(in: budget, for: [.income], amount: \.amountPlanned)
    }

    public static func plannedSpendingTotal(in budget: BWBudget) -> UInt64 {
        total(in: budget, for: [.expenses, .debt], amount: \.amountPlanned)
    }

    public static func actualSpendingTotal(in budget: BWBudget) -> UInt64 {
        total(in: budget, for: [.expenses, .debt], amount: \.amountActual)
    }

    public static func plannedSavingsTotal(in budget: BWBudget) -> UInt64 {
        total(in: budget, for: [.savings], amount: \.amountPlanned)
    }

    public static func leftToBudgetTotal(in budget: BWBudget) -> Int64? {
        guard
            let income = Int64(exactly: incomeTotal(in: budget)),
            let plannedSpending = Int64(exactly: plannedSpendingTotal(in: budget)),
            let plannedSavings = Int64(exactly: plannedSavingsTotal(in: budget))
        else {
            return nil
        }

        let afterSpending = income.subtractingReportingOverflow(plannedSpending)

        guard !afterSpending.overflow else {
            return nil
        }

        let afterSavings = afterSpending.partialValue.subtractingReportingOverflow(plannedSavings)

        guard !afterSavings.overflow else {
            return nil
        }

        return afterSavings.partialValue
    }

    public static func allocationSegments(
        in budget: BWBudget,
        amountMode: BWReportingAmountMode
    ) -> [BWReportingAmountSegment] {
        [
            BWReportingAmountSegment(
                title: "Expenses",
                amount: total(in: budget, for: [.expenses], amount: amountMode.amountKeyPath)
            ),
            BWReportingAmountSegment(
                title: "Savings",
                amount: total(in: budget, for: [.savings], amount: amountMode.amountKeyPath)
            ),
            BWReportingAmountSegment(
                title: "Debt",
                amount: total(in: budget, for: [.debt], amount: amountMode.amountKeyPath)
            )
        ].filter { $0.amount > 0 }
    }

    public static func categorySegments(
        in budget: BWBudget,
        categoryType: BWCategoryType,
        amountMode: BWReportingAmountMode
    ) -> [BWReportingAmountSegment] {
        budget.orderedCategories(for: categoryType)
            .filter { $0[keyPath: amountMode.amountKeyPath] > 0 }
            .map {
                BWReportingAmountSegment(
                    title: $0.title,
                    amount: $0[keyPath: amountMode.amountKeyPath]
                )
            }
    }

    public static func incomeVsAllocationSegments(
        in budget: BWBudget,
        plannedRowTitle: String,
        actualRowTitle: String
    ) -> [BWReportingComparisonAmountSegment] {
        [
            BWReportingComparisonAmountSegment(
                rowTitle: "Income",
                componentTitle: "Income",
                amount: total(in: budget, for: [.income], amount: \.amountPlanned)
            ),
            BWReportingComparisonAmountSegment(
                rowTitle: plannedRowTitle,
                componentTitle: "Expenses",
                amount: total(in: budget, for: [.expenses], amount: \.amountPlanned)
            ),
            BWReportingComparisonAmountSegment(
                rowTitle: plannedRowTitle,
                componentTitle: "Savings",
                amount: total(in: budget, for: [.savings], amount: \.amountPlanned)
            ),
            BWReportingComparisonAmountSegment(
                rowTitle: plannedRowTitle,
                componentTitle: "Debt",
                amount: total(in: budget, for: [.debt], amount: \.amountPlanned)
            ),
            BWReportingComparisonAmountSegment(
                rowTitle: actualRowTitle,
                componentTitle: "Expenses",
                amount: total(in: budget, for: [.expenses], amount: \.amountActual)
            ),
            BWReportingComparisonAmountSegment(
                rowTitle: actualRowTitle,
                componentTitle: "Savings",
                amount: total(in: budget, for: [.savings], amount: \.amountActual)
            ),
            BWReportingComparisonAmountSegment(
                rowTitle: actualRowTitle,
                componentTitle: "Debt",
                amount: total(in: budget, for: [.debt], amount: \.amountActual)
            )
        ].filter { $0.amount > 0 }
    }

    public static func incomeVsAllocationTotals(in budget: BWBudget) -> [BWReportingComparisonTotal] {
        let outflowTypes: Set<BWCategoryType> = [.expenses, .savings, .debt]

        return [
            BWReportingComparisonTotal(
                title: "Income",
                amount: total(in: budget, for: [.income], amount: \.amountPlanned)
            ),
            BWReportingComparisonTotal(
                title: "Planned",
                amount: total(in: budget, for: outflowTypes, amount: \.amountPlanned)
            ),
            BWReportingComparisonTotal(
                title: "Actual",
                amount: total(in: budget, for: outflowTypes, amount: \.amountActual)
            )
        ]
    }
}
