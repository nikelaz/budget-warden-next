
/* 
 * Budget Warden
 * Copyright (c) 2026 Lazarov & Co EOOD
 * Author: Nikola Lazarov
 *
 * Licensed under the Source-Available Educational License. 
 * See the LICENSE file in the project root for full terms.
 */

import BWAppleCore
import SwiftUI

struct CreateBudgetView: View {
    @EnvironmentObject var store: BWStore
    @EnvironmentObject var windowStore: BWWindowStore

    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    @State private var title: Swift.String
    @State private var selectedTemplate: BWBudgetTemplateSelection = .basicMonthly
    @State private var recentTemplates: [BWBudgetTemplateSelection] = []

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

                    Text("Monthly Budget")
                        .tag(BWBudgetTemplateSelection.basicMonthly)

                    Text("Empty Budget")
                        .tag(BWBudgetTemplateSelection.empty)

                    Text("Previous budget")
                        .selectionDisabled(true)

                    ForEach(recentTemplates, id: \.self) { template in
                        if case .previousBudget(let budget) = template {
                            Text(budget.title)
                                .tag(template)
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
                    Task(priority: .userInitiated) {
                        if await store.createBudget(
                            title: title,
                            template: selectedTemplate,
                            windowStore: windowStore
                        ) {
                            onCreateSuccess()
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
            }
        }
        .padding(20)
        .task(id: store.recentFiles) {
            recentTemplates = store.recentBudgetTemplates()
        }
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
