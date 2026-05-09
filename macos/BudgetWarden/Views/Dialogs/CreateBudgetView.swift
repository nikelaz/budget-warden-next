/* 
 * Budget Warden Core
 * Copyright (c) 2026 Lazarov & Co EOOD
 * Author: Nikola Lazarov
 *
 * Licensed under the Source-Available Educational License. 
 * See the LICENSE file in the project root for full terms.
 *
 */

import Foundation
import SwiftUI

private enum BudgetTemplateSelection: Hashable {
    case basic
    case blank
    case previous(URL)
}

struct CreateBudgetView: View {
    @ObservedObject var store: BudgetStore
    let onSave: (BudgetDraft) -> Void
    let onCancel: () -> Void
    let basicTemplateURL: URL?

    @State private var title: Swift.String
    @State private var selectedTemplate: BudgetTemplateSelection = .basic

    private var isValid: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    init(store: BudgetStore, onSave: @escaping (BudgetDraft) -> Void, onCancel: @escaping () -> Void) {
        self.store = store
        self.onSave = onSave
        self.onCancel = onCancel
        self.basicTemplateURL = Bundle.main.url(forResource: "basic-budget", withExtension: "budget")
        self._title = State(initialValue: Self.currentMonthTitle())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("New Budget")
                .font(.title2)
                .fontWeight(.semibold)

            Form {
                TextField("Title", text: $title)
                    .accessibilityIdentifier("budget-title-field")
                    .padding(.bottom, 10)

                Picker(selection: $selectedTemplate, content: {
                    Text("Templates")
                        .selectionDisabled(true)

                    Text("Basic budget (recommended)")
                        .tag(BudgetTemplateSelection.basic)

                    Text("Blank budget")
                        .tag(BudgetTemplateSelection.blank)

                    Text("Previous budget")
                        .selectionDisabled(true)

                    ForEach(store.budgets) { budget in
                        Text(budget.title)
                            .tag(BudgetTemplateSelection.previous(budget.url))
                    }
                }, label: {
                    Text("Template")
                })
            }

            HStack {
                Spacer()

                Button("Cancel", role: .cancel) {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)

                Button("Save") {
                    saveBudget()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
            }
        }
        .padding()
    }

    private func saveBudget() {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)

        let templateURL: URL?

        switch selectedTemplate {
        case .basic:
            templateURL = basicTemplateURL
        case .blank:
            templateURL = nil
        case .previous(let url):
            templateURL = url
        }

        onSave(BudgetDraft(title: trimmedTitle, templateURL: templateURL))
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
