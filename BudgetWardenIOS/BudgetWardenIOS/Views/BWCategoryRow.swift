/*
 * Budget Warden
 * Copyright (c) 2026 Lazarov & Co EOOD
 * Author: Nikola Lazarov
 *
 * Licensed under the Source-Available Educational License.
 * See the LICENSE file in the project root for full terms.
 *
 */

import AppleCore
import SwiftUI

struct BWCategoryRow: View {
    let category: BWCategory
    let selectedAmount: BWCategoryAmount
    let currency: BWCurrency

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(category.title)
                .font(.body)
                .accessibilityIdentifier("categoryTitle_\(category.title)")

            Spacer()

            Text(selectedAmount.amount(for: category).formattedMoneyAmount(currency: currency))
                .font(.body.monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("categoryAmount_\(category.title)")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
