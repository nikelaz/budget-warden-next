/* 
 * Budget Warden
 * Copyright (c) 2026 Lazarov & Co EOOD
 * Author: Nikola Lazarov
 *
 * Licensed under the Source-Available Educational License. 
 * See the LICENSE file in the project root for full terms.
 *
 */

import SwiftUI

struct BudgetRowView: View {
    let budget: BudgetRow

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(budget.title)
                .font(.headline)

            Text(budget.url.lastPathComponent)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}
