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

struct CreateCategoryView: View {
    let type: BudgetCategoryType
    let onSave: (Swift.String, UInt64) -> Void
    let onCancel: () -> Void

    @State private var title = ""
    @State private var plannedAmount = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("New \(type.title) Category")
                .font(.headline)

            Form {
                TextField("Title", text: $title)

                TextField("Planned Amount", text: $plannedAmount)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                Spacer()

                Button("Cancel", role: .cancel) {
                    onCancel()
                }

                Button("Save") {
                    onSave(trimmedTitle, parsedPlannedAmount ?? 0)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(trimmedTitle.isEmpty || parsedPlannedAmount == nil)
            }
        }
        .padding()
    }

    private var trimmedTitle: Swift.String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var parsedPlannedAmount: UInt64? {
        UInt64.parseMoneyAmount(plannedAmount, emptyValue: 0)
    }
}
