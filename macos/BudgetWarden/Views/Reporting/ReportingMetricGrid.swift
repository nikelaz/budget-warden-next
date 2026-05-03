import SwiftUI

struct ReportingMetricGrid: View {
    let budget: BudgetDocument
    let currency: AppCurrency
    let scope: ReportingScope

    private var incomeTotal: UInt64 {
        budget.categories(for: .income).total(\.amountPlanned)
    }

    private var plannedSpendingTotal: UInt64 {
        budget.categories(for: .expenses).total(\.amountPlanned) +
            budget.categories(for: .debt).total(\.amountPlanned)
    }

    private var actualSpendingTotal: UInt64 {
        budget.categories(for: .expenses).total(\.amountActual) +
            budget.categories(for: .debt).total(\.amountActual)
    }

    private var plannedSavingsTotal: UInt64 {
        budget.categories(for: .savings).total(\.amountPlanned)
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
