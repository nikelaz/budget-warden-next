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
        Text(budget.title)
            .font(.headline)
    }
}
