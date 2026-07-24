/* 
 * Budget Warden
 * Copyright (c) 2026 Lazarov & Co EOOD
 * Author: Nikola Lazarov
 *
 * Licensed under the Source-Available Educational License. 
 * See the LICENSE file in the project root for full terms.
 */

import SwiftUI

struct BWWindowCategoryTransactions: Scene {
    @EnvironmentObject var store: BWStore

    var body: some Scene {
        WindowGroup(
            "Category Transactions",
            id: "window-category-transactions",
            for: BWCategoryTransactionsWindowValue.self
        ) { $value in
            if let value {
                BWCategoryTransactionsWindow(value: value)
                    .environmentObject(store)
            }
            else {
                ContentUnavailableView(
                    "Category Not Found",
                    systemImage: "folder.badge.questionmark"
                )
            }
        }
        .defaultSize(width: 900, height: 560)
        .restorationBehavior(.disabled)
    }
}
