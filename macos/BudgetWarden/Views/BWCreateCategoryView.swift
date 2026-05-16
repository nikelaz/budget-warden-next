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

struct CreateCategoryView: View {
    @EnvironmentObject var store: BWStore

    let type: BWCategoryType
    let hint: String
    let onClose: () -> Void

    @State private var title = ""
    @State private var plannedAmount = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("New \(type.title) Category")
                .font(.headline)

            Form {
                TextField("Title", text: $title, prompt: Text(hint))
                TextField("Planned Amount", text: $plannedAmount, prompt: Text("0.00"))
            }

            HStack {
                Spacer()

                Button("Cancel", role: .cancel) {
                    onClose()
                }

                Button("Save") {
                    //onSave(trimmedTitle, parsedPlannedAmount ?? 0)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(trimmedTitle.isEmpty || parsedPlannedAmount == nil)
            }
        }
        .padding(20)
    }

    private var trimmedTitle: Swift.String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var parsedPlannedAmount: UInt64? {
        UInt64.parseMoneyAmount(plannedAmount, emptyValue: 0)
    }
}
