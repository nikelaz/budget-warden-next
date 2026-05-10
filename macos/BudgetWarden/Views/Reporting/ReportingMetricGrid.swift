/* 
 * Budget Warden Core
 * Copyright (c) 2026 Lazarov & Co EOOD
 * Author: Nikola Lazarov
 *
 * Licensed under the Source-Available Educational License. 
 * See the LICENSE file in the project root for full terms.
 *
 */

import SwiftUI

struct ReportingMetricGrid: View {
    @ObservedObject var store: BWStore
    let budgetURL: URL
    let currency: AppCurrency
    let scope: ReportingScope

    private var incomeTotal: UInt64 {
        store.categoryTotal(type: .income, field: .planned, in: budgetURL)
    }

    private var plannedSpendingTotal: UInt64 {
        store.categoryTotal(type: .expenses, field: .planned, in: budgetURL) +
            store.categoryTotal(type: .debt, field: .planned, in: budgetURL)
    }

    private var actualSpendingTotal: UInt64 {
        store.categoryTotal(type: .expenses, field: .actual, in: budgetURL) +
            store.categoryTotal(type: .debt, field: .actual, in: budgetURL)
    }

    private var plannedSavingsTotal: UInt64 {
        store.categoryTotal(type: .savings, field: .planned, in: budgetURL)
    }

    private var leftToBudgetTotal: Int64 {
        Int64(incomeTotal) - Int64(plannedSpendingTotal) - Int64(plannedSavingsTotal)
    }

    private var plannedSpendingMetricColor: Color {
        plannedSpendingTotal > incomeTotal ? Color(nsColor: .systemRed) : .primary
    }

    private var actualSpendingMetricColor: Color {
        actualSpendingTotal > plannedSpendingTotal ? Color(nsColor: .systemRed) : Color(nsColor: .systemGreen)
    }

    private var leftToBudgetMetricColor: Color {
        leftToBudgetTotal < 0 ? Color(nsColor: .systemRed) : .primary
    }

    var body: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: scope == .fullPage ? 170 : 130), spacing: 20, alignment: .topLeading)],
            alignment: .leading,
            spacing: 20
        ) {
            ReportMetricView(
                title: "Income",
                value: incomeTotal,
                currency: currency
            )
            ReportMetricView(
                title: "Planned Spending",
                value: plannedSpendingTotal,
                currency: currency,
                valueColor: plannedSpendingMetricColor
            )
            ReportMetricView(
                title: "Actual Spending",
                value: actualSpendingTotal,
                currency: currency,
                valueColor: actualSpendingMetricColor
            )
            ReportMetricView(title: "Savings", value: plannedSavingsTotal, currency: currency)
            ReportMetricView(
                title: "Left to Budget",
                signedValue: leftToBudgetTotal,
                currency: currency,
                valueColor: leftToBudgetMetricColor
            )
        }
    }

}
