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

struct CategoryRowView: View {
    @ObservedObject var store: BWStore
    let budgetURL: URL
    let categoryID: Int
    let currency: AppCurrency

    var body: some View {
        let category = store.category(categoryID, in: budgetURL)

        VStack(alignment: .leading, spacing: 3) {
            Text(category?.title.swiftString() ?? "")
                .font(.headline)
                .fontWeight(.medium)

            Text(summary(for: category))
                .font(.body)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private func summary(for category: BWCategoryView?) -> Swift.String {
        var parts = [
            "Planned \((category?.amount_planned ?? 0).formattedMoneyAmount(currency: currency))",
            "Actual \((category?.amount_actual ?? 0).formattedMoneyAmount(currency: currency))"
        ]

        if category?.type == .savings || category?.type == .debt {
            parts.append("Accumulated \((category?.amount_accumulated ?? 0).formattedMoneyAmount(currency: currency))")
        }

        return parts.joined(separator: " | ")
    }
}
