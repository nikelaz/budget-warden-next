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

struct BWCreateBudgetView: View {
    let store: BWAppStore

    @Environment(\.dismiss) private var dismiss

    @State private var title: String
    @State private var selectedTemplate: BWTemplateSelection = .basic

    init(store: BWAppStore) {
        self.store = store
        _title = State(initialValue: Self.currentMonthTitle())
    }

    private var isValid: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Budget") {
                    TextField("Title", text: $title)
                }

                Section("Start From") {
                    Picker("Template", selection: $selectedTemplate) {
                        Text("Basic budget")
                            .tag(BWTemplateSelection.basic)

                        Text("Blank budget")
                            .tag(BWTemplateSelection.blank)

                        if !store.budgets.isEmpty {
                            Divider()

                            ForEach(store.budgets) { budget in
                                if let budgetURL = budget.url {
                                    Text(budget.title)
                                        .tag(BWTemplateSelection.previous(budgetURL))
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("New Budget")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        Task {
                            if await store.createBudget(title: title, template: selectedTemplate) {
                                dismiss()
                            }
                        }
                    }
                    .disabled(!isValid)
                }
            }
        }
    }

    private static func currentMonthTitle(calendar: Calendar = .current, now: Date = Date()) -> String {
        let components = calendar.dateComponents([.year, .month], from: now)
        let titleDate = calendar.date(from: components) ?? now

        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "LLLL yyyy"

        return formatter.string(from: titleDate)
    }
}
