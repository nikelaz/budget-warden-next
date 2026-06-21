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

struct BWSummaryRow: View {
    let budget: BWBudget

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(budget.title)
                .font(.headline)

            Text("\(budget.categories.count) categories")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}
