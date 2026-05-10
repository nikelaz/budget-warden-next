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

struct CategorySectionView: View {
    @ObservedObject var store: BWStore
    let budgetURL: URL
    let type: BudgetCategoryType
    let currency: AppCurrency
    let onAddCategory: () -> Void

    private var categoryIDs: [Int] {
        store.categoryIDs(for: type, in: budgetURL)
    }

    var body: some View {
        Section {
            if categoryIDs.isEmpty {
                Text("No categories")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(categoryIDs, id: \.self) { categoryID in
                    CategoryRowView(
                        store: store,
                        budgetURL: budgetURL,
                        categoryID: categoryID,
                        currency: currency
                    )
                }
            }
        } header: {
            HStack {
                Text(type.title)

                Spacer()

                Button {
                    onAddCategory()
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("Add \(type.title) Category")
            }
        }
    }
}
