/* 
 * Budget Warden
 * Copyright (c) 2026 Lazarov & Co EOOD
 * Author: Nikola Lazarov
 *
 * Licensed under the Source-Available Educational License. 
 * See the LICENSE file in the project root for full terms.
 */

import SwiftUI
import BWCore

struct CreateTransactionView: View {
    @EnvironmentObject var store: BWStore
    @EnvironmentObject var windowStore: BWWindowStore

    let initialCategoryID: UUID?
    let onClose: () -> Void

    @State private var title = ""
    @State private var description = ""
    @State private var amount = ""
    @State private var date = Date()
    @State private var isShowingDetails = false
    @State private var selectedCategoryID: UUID?

    init(initialCategoryID: UUID? = nil, onClose: @escaping () -> Void) {
        self.initialCategoryID = initialCategoryID
        self.onClose = onClose
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Transaction")
                .font(.headline)

            VStack(alignment: .leading, spacing: 12) {
                field("Category") {
                    Picker("Category", selection: $selectedCategoryID) {
                        ForEach(BWCategoryType.allCases, id: \.self) { type in
                            let categories = orderedCategories(for: type)

                            if !categories.isEmpty {
                                Text(type.toString())
                                    .font(.headline)
                                    .selectionDisabled(true)

                                ForEach(categories) { category in
                                    Text(category.title)
                                        .tag(Optional(category.id))
                                }
                            }
                        }
                    }
                    .labelsHidden()
                    .accessibilityIdentifier("transactionCategoryPicker")
                }

                field("Title") {
                    TextField("Title", text: $title, prompt: Text("Groceries at supermarket"))
                        .accessibilityIdentifier("transactionTitleTextField")
                }

                field("Amount") {
                    HStack(spacing: 8) {
                        TextField("Amount", text: $amount, prompt: Text("0.00"))
                            .accessibilityIdentifier("transactionAmountTextField")
                            .textFieldStyle(.roundedBorder)
                            .foregroundStyle(parsedAmount == nil && !amount.isEmpty ? .red : .primary)

                        /*
                        Text(store.selectedCurrency.symbol)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                         */
                    }
                }

                Button {
                    isShowingDetails.toggle()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .rotationEffect(.degrees(isShowingDetails ? 90 : 0))

                        Text("More Details")

                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if isShowingDetails {
                    VStack(alignment: .leading, spacing: 12) {
                        field("Description") {
                            TextField("Description", text: $description, prompt: Text("Add a note"))
                        }

                        field("Date") {
                            DatePicker(
                                "Date",
                                selection: $date,
                                displayedComponents: .date
                            )
                            .labelsHidden()
                        }
                    }
                    .padding(.top, 8)
                }
            }

            HStack {
                Spacer()

                Button("Cancel", role: .cancel) {
                    onClose()
                }

                Button("Save") {
                    Task(priority: .userInitiated) {
                        guard
                            let selectedCategoryID,
                            let amount = parsedAmount
                        else {
                            return
                        }

                        if await store.createTransaction(
                            categoryID: selectedCategoryID,
                            title: trimmedTitle,
                            description: trimmedDescription,
                            date: date,
                            amount: amount,
                            windowStore: windowStore
                        ) {
                            onClose()
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
                .accessibilityIdentifier("transactionSaveButton")
            }
        }
        .padding(20)
        .onAppear {
            selectedCategoryID = initialCategoryID ?? orderedCategories().first?.id
        }
    }

    private func field<Content: View>(
        _ title: Swift.String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)

            content()
        }
    }

    private func orderedCategories(for type: BWCategoryType? = nil) -> [BWCategory] {
        guard let budget = store.currentBudget else {
            return []
        }

        return budget.orderedCategories(for: type)
    }

    private var isValid: Bool {
        guard
            selectedCategoryID != nil,
            !trimmedTitle.isEmpty,
            let parsedAmount
        else {
            return false
        }

        return parsedAmount > 0
    }

    private var trimmedTitle: Swift.String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedDescription: Swift.String {
        description.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var parsedAmount: UInt64? {
        UInt64.parseMoneyAmount(amount)
    }
}
