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
import BudgetWardenAppleCore

struct CreateCategoryView: View {
    @EnvironmentObject var store: BWStore
    @EnvironmentObject var windowStore: BWWindowStore

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
                    .accessibilityIdentifier("createCategoryTitleTextField")
                TextField("Planned Amount", text: $plannedAmount, prompt: Text("0.00"))
                    .accessibilityIdentifier("createCategoryPlannedAmountTextField")
            }

            HStack {
                Spacer()

                Button("Cancel", role: .cancel) {
                    onClose()
                }

                Button("Save") {
                    Task(priority: .userInitiated) {
                        guard let plannedAmount = parsedPlannedAmount else {
                            return
                        }

                        if await store.createCategory(
                            title: trimmedTitle,
                            plannedAmount: plannedAmount,
                            categoryType: type,
                            windowStore: windowStore
                        ) {
                            onClose()
                        }
                    }
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

struct CreateGeneralCategoryView: View {
    @EnvironmentObject var store: BWStore
    @EnvironmentObject var windowStore: BWWindowStore

    let onClose: () -> Void

    @State private var type: BWCategoryType = .expenses
    @State private var title = ""
    @State private var plannedAmount = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("New Category")
                .font(.headline)

            Form {
                Picker("Type", selection: $type) {
                    ForEach(BWCategoryType.allCases, id: \.self) { categoryType in
                        Text(categoryType.title)
                            .tag(categoryType)
                    }
                }
                .accessibilityIdentifier("createCategoryTypePicker")

                TextField("Title", text: $title, prompt: Text(hint))
                    .accessibilityIdentifier("createCategoryTitleTextField")
                TextField("Planned Amount", text: $plannedAmount, prompt: Text("0.00"))
                    .accessibilityIdentifier("createCategoryPlannedAmountTextField")
            }

            HStack {
                Spacer()

                Button("Cancel", role: .cancel) {
                    onClose()
                }

                Button("Save") {
                    Task(priority: .userInitiated) {
                        guard let plannedAmount = parsedPlannedAmount else {
                            return
                        }

                        if await store.createCategory(
                            title: trimmedTitle,
                            plannedAmount: plannedAmount,
                            categoryType: type,
                            windowStore: windowStore
                        ) {
                            onClose()
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(trimmedTitle.isEmpty || parsedPlannedAmount == nil)
            }
        }
        .padding(20)
    }

    private var hint: String {
        switch type {
            case .income:
                return "Salary"
            case .expenses:
                return "Groceries"
            case .savings:
                return "Emergency Fund"
            case .debt:
                return "Mortgage"
        }
    }

    private var trimmedTitle: Swift.String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var parsedPlannedAmount: UInt64? {
        UInt64.parseMoneyAmount(plannedAmount, emptyValue: 0)
    }
}
