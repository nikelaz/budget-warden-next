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
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text(conflict.item.title)
                    .font(.title3)
                    .fontWeight(.semibold)

                Text("This item changed in two places. Choose the version to keep.")
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .top, spacing: 14) {
                conflictColumn(title: "Version A", choice: .local)
                conflictColumn(title: "Version B", choice: .latest)
            }

            HStack {
                Spacer()

                Button("Cancel", role: .cancel) {
                    dismiss()
                }
                .disabled(isResolving)
            }
        }
        .padding(24)
        .frame(minWidth: 640, idealWidth: 720)
    }

    private func conflictColumn(
        title: String,
        choice: BWBudgetConflictChoice
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)

            Divider()

            conflictRows(for: choice)

            Spacer(minLength: 8)

            Button {
                isResolving = true
                resolve(choice)
            } label: {
                Label("Keep This Version", systemImage: "checkmark.circle")
            }
            .buttonStyle(.borderedProminent)
            .disabled(isResolving)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 260, alignment: .topLeading)
        .background(.thinMaterial)
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
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
            ForEach(rows, id: \.0) { label, value in
                GridRow {
                    Text(label)
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

