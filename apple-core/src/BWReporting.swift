/*
 * Budget Warden
 * Copyright (c) 2026 Lazarov & Co EOOD
 * Author: Nikola Lazarov
 *
 * Licensed under the Source-Available Educational License.
 * See the LICENSE file in the project root for full terms.
 */

import BWCore

extension BWReportingAmountMode: @retroactive Identifiable {
    public var id: Self { self }
}

public extension BWReportingAmountMode {
    var title: String {
        switch self {
        case .planned: "Planned"
        case .actual: "Actual"
        }
    }
}

public extension BWCategoryType {
    var title: String { toString() }
}

public extension BWReportingComparisonRow {
    var title: String {
        switch self {
        case .income: "Income"
        case .planned: "Planned"
        case .actual: "Actual"
        }
    }
}

public extension BWReportingComponent {
    var title: String {
        switch self {
        case .income: "Income"
        case .expenses: "Expenses"
        case .savings: "Savings"
        case .debt: "Debt"
        }
    }
}

public extension BWReportingSummary {
    func allocationSegments(
        amountMode: BWReportingAmountMode
    ) -> [BWReportingAllocationSegment] {
        allocationSegments.filter { $0.amountMode == amountMode }
    }

    func categorySegments(
        categoryType: BWCategoryType,
        amountMode: BWReportingAmountMode
    ) -> [BWReportingCategorySegment] {
        categorySegments.filter {
            $0.categoryType == categoryType && $0.amountMode == amountMode
        }
    }
}
