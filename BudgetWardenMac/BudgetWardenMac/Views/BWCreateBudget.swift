
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
import AppleCore

typealias BudgetTemplateSelection = BWBudgetTemplateSelection

struct CreateBudgetView: View {
    @EnvironmentObject var store: BWStore
    @EnvironmentObject var windowStore: BWWindowStore

    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    @State private var title: Swift.String
    @State private var selectedTemplate: BudgetTemplateSelection = .basic

    let onCreateSuccess: () -> Void

    init(onCreateSuccess: @escaping () -> Void = {}) {
        self.onCreateSuccess = onCreateSuccess
        self._title = State(initialValue: Self.currentMonthTitle())
    }

    private var isValid: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("New Budget")
                .font(.title2)
                .fontWeight(.semibold)

            Form {
                TextField("Title", text: $title)
                    .padding(.bottom, 10)
                    .accessibilityIdentifier("titleTextField")

                Picker(selection: $selectedTemplate, content: {
                    Text("Templates")
                        .selectionDisabled(true)

                    Text("Basic budget (recommended)")
                        .tag(BudgetTemplateSelection.basic)

                    Text("Blank budget")
                        .tag(BudgetTemplateSelection.blank)

                    Text("Previous budget")
                        .selectionDisabled(true)

                    ForEach(store.budgetsInVault) { budget in
                        if let budgetUrl = budget.url {
                            Text(budget.title)
                                .tag(BudgetTemplateSelection.previous(budgetUrl))
                        }
                    }
                }, label: {
                    Text("Template")
                })
            }

            HStack {
                Spacer()

                Button("Cancel", role: .cancel) {
                    windowStore.closeBudgetDialog()
                }
                .keyboardShortcut(.cancelAction)

                Button("Save") {
                    Task {
                        if await store.createBudget(
                            title: title,
                            template: selectedTemplate,
                            windowStore: windowStore
                        ) {
                            windowStore.closeBudgetDialog()
                            onCreateSuccess()
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
            }
        }
        .padding(20)
    }

    private static func currentMonthTitle(calendar: Calendar = .current, now: Date = Date()) -> Swift.String {
        let components = calendar.dateComponents([.year, .month], from: now)
        let titleDate = calendar.date(from: components) ?? now

        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "LLLL yyyy"

        return formatter.string(from: titleDate)
    }
}
