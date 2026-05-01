//
//  ContentView.swift
//  BudgetWarden
//
//  Created by Nikola Lazarov on 1.05.26.
//

import SwiftUI

struct ContentView: View {
    private let sampleBudget = SampleBudget.create()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "creditcard.and.123")
                .imageScale(.large)
                .foregroundStyle(.tint)

            Text(sampleBudget.title)
                .font(.title2)
                .fontWeight(.semibold)

            Text(sampleBudget.period)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(minWidth: 320, alignment: .leading)
    }
}

private struct SampleBudget {
    let title: Swift.String
    let period: Swift.String

    static func create() -> SampleBudget {
        var periodStart = BWDate(timestamp: 0)
        var periodEnd = BWDate(timestamp: 0)

        guard bw_date_create(&periodStart, 2026, 5, 1) == 1,
              bw_date_create(&periodEnd, 2026, 5, 31) == 1 else {
            return SampleBudget(title: "Budget creation failed", period: "Invalid date")
        }

        var budget = Budget()

        guard budget_create(&budget, "May Budget", periodStart, periodEnd) == 0 else {
            return SampleBudget(title: "Budget creation failed", period: "Invalid budget")
        }

        defer {
            budget_free(&budget)
        }

        let title = budget.title.data.map { Swift.String(cString: $0) } ?? "Untitled Budget"
        let period = "\(Self.format(periodStart)) - \(Self.format(periodEnd))"

        return SampleBudget(title: title, period: period)
    }

    private static func format(_ date: BWDate) -> Swift.String {
        var date = date
        let year = bw_date_get_year(&date)
        let month = bw_date_get_month(&date)
        let day = bw_date_get_day(&date)

        return Swift.String(format: "%04d-%02d-%02d", year, month, day)
    }
}

#Preview {
    ContentView()
}
