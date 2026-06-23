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

struct BWBudgetConflictResolutionView: View {
    let conflict: BWBudgetSaveConflict
    let resolve: (BWBudgetConflictChoice) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var isResolving = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("This item changed in two places. Choose the version to keep.")
                        .foregroundStyle(.secondary)

                    conflictColumn(title: "Version A", choice: .local)
                    conflictColumn(title: "Version B", choice: .latest)
                }
                .padding()
            }
            .navigationTitle(conflict.item.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .disabled(isResolving)
                }
            }
        }
    }

    private func conflictColumn(
        title: String,
        choice: BWBudgetConflictChoice
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)

            conflictRows(for: choice)

            Button {
                isResolving = true
                resolve(choice)
            } label: {
                Label("Keep This Version", systemImage: "checkmark.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isResolving)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func conflictRows(for choice: BWBudgetConflictChoice) -> some View {
        switch conflict.item {
            case .budget(let localTitle, let latestTitle):
                valueRows([
                    ("Title", choice == .local ? localTitle : latestTitle)
                ])
            case .category(let local, let latest):
                categoryRows(choice == .local ? local : latest)
            case .transaction(let local, let latest):
                transactionRows(choice == .local ? local : latest)
        }
    }

    @ViewBuilder
    private func categoryRows(_ category: BWCategory?) -> some View {
        if let category {
            valueRows([
                ("Title", category.title),
                ("Type", category.categoryType.title),
                ("Planned", formatAmount(category.amountPlanned)),
                ("Accumulated", formatAmount(category.amountAccumulated)),
                ("Transactions", "\(category.transactions.count)")
            ])
        }
        else {
            Text("Deleted")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func transactionRows(_ value: BWTransactionConflictValue?) -> some View {
        if let value {
            valueRows([
                ("Category", value.categoryTitle),
                ("Title", value.transaction.title),
                ("Description", value.transaction.description.isEmpty ? "None" : value.transaction.description),
                ("Date", value.transaction.date.formatted(date: .abbreviated, time: .omitted)),
                ("Amount", formatAmount(value.transaction.amount))
            ])
        }
        else {
            Text("Deleted")
                .foregroundStyle(.secondary)
        }
    }

    private func valueRows(_ rows: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(rows, id: \.0) { label, value in
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(value)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private func formatAmount(_ amount: UInt64) -> String {
        String(format: "%.2f", Double(amount) / 100)
    }
}

