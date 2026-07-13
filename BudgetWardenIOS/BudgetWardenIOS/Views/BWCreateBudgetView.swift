/*
 * Budget Warden
 * Copyright (c) 2026 Lazarov & Co EOOD
 * Author: Nikola Lazarov
 *
 * Licensed under the Source-Available Educational License.
 * See the LICENSE file in the project root for full terms.
 *
 */

import BudgetWardenAppleCore
import SwiftUI

struct BWCreateBudgetView: View {
    let store: BWStore

    @Environment(\.dismiss) private var dismiss

    @State private var title: String
    @State private var selectedTemplate: BWTemplateSelection = .basic
    @State private var selectedLocation: BWVaultLocation

    init(store: BWStore) {
        self.store = store
        _title = State(initialValue: Self.currentMonthTitle())
        _selectedLocation = State(initialValue: store.preferredBudgetLocation)
    }

    private var isValid: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Budget") {
                    TextField("Title", text: $title)
                        .accessibilityIdentifier("createBudgetTitleTextField")
                }

                Section("Storage") {
                    Picker("Storage", selection: $selectedLocation) {
                        Text("iCloud").tag(BWVaultLocation.iCloud)
                        Text("Google Drive").tag(BWVaultLocation.googleDrive)
                        Text("Local File").tag(BWVaultLocation.local)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("createBudgetStoragePicker")
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
                    .accessibilityIdentifier("createBudgetTemplatePicker")
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
                            if await store.createBudget(
                                title: title,
                                template: selectedTemplate,
                                location: selectedLocation
                            ) {
                                dismiss()
                            }
                        }
                    }
                    .accessibilityIdentifier("createBudgetSaveButton")
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
