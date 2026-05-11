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

struct CreateTransactionView: View {
    @ObservedObject var store: BWStore
    let budgetURL: URL
    let onSave: (TransactionDraft) -> Void
    let onCancel: () -> Void

    @State private var title = ""
    @State private var description = ""
    @State private var amount = ""
    @State private var date = Date()
    @State private var isShowingDetails = false
    @State private var selectedCategoryID: Int

    init(
        store: BWStore,
        budgetURL: URL,
        initialCategoryID: Int? = nil,
        onSave: @escaping (TransactionDraft) -> Void,
        onCancel: @escaping () -> Void
    ) {
        _store = ObservedObject(wrappedValue: store)
        self.budgetURL = budgetURL
        self.onSave = onSave
        self.onCancel = onCancel
        _selectedCategoryID = State(initialValue: initialCategoryID ?? store.categoryIDs(in: budgetURL).first ?? 0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Transaction")
                .font(.headline)

            VStack(alignment: .leading, spacing: 12) {
                field("Category") {
                    Picker("Category", selection: $selectedCategoryID) {
                        ForEach(BudgetCategoryType.allCases) { type in
                            let categoryIDs = store.categoryIDs(for: type, in: budgetURL)

                            if !categoryIDs.isEmpty {
                                Text(type.title)
                                    .font(.headline)
                                    .selectionDisabled(true)

                                ForEach(categoryIDs, id: \.self) { categoryID in
                                    Text(store.category(categoryID, in: budgetURL)?.title.swiftString() ?? "")
                                        .tag(categoryID)
                                }
                            }
                        }
                    }
                    .labelsHidden()
                }

                field("Title") {
                    TextField("Title", text: $title, prompt: Text("Groceries at supermarket"))
                        .accessibilityIdentifier("transaction-title-field")
                }

                field("Amount") {
                    HStack(spacing: 8) {
                        TextField("Amount", text: $amount, prompt: Text("0.00"))
                            .textFieldStyle(.roundedBorder)
                            .accessibilityIdentifier("transaction-amount-field")

                        Text(store.selectedCurrency.symbol)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("transaction-amount-currency-label")
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
                                .accessibilityIdentifier("transaction-description-field")
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
                    onCancel()
                }

                Button("Save") {
                    if let draft {
                        onSave(draft)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(draft == nil)
            }
        }
        .padding()
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

    private var draft: TransactionDraft? {
        guard
            !trimmedTitle.isEmpty,
            let parsedAmount,
            parsedAmount > 0,
            let transactionDate
        else {
            return nil
        }

        return TransactionDraft(
            categoryID: selectedCategoryID,
            title: trimmedTitle,
            description: trimmedDescription,
            date: transactionDate,
            amount: parsedAmount
        )
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

    private var transactionDate: BWDate? {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: date)

        guard
            let year = components.year,
            let month = components.month,
            let day = components.day
        else {
            return nil
        }

        guard BWDate.isValid(year: Int32(year), month: Int32(month), day: Int32(day)) else {
            return nil
        }

        return BWDate(year: Int32(year), month: Int32(month), day: Int32(day))
    }
}
