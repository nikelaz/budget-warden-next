import SwiftUI

struct TransactionsView: View {
    let budgets: [BudgetDocument]
    let budget: BudgetDocument
    @Binding var selectedBudgetID: BudgetDocument.ID?
    let onCreateBudget: () -> Void
    let onAddTransaction: (TransactionDraft) -> Void

    @State private var isCreatingTransaction = false

    var body: some View {
        List {
            if budget.transactions.isEmpty {
                ContentUnavailableView(
                    "No Transactions",
                    systemImage: "list.bullet.rectangle"
                )
            } else {
                ForEach(budget.transactions) { transaction in
                    TransactionRowView(transaction: transaction)
                }
            }
        }
        .navigationTitle("Transactions")
        .toolbar {
            BudgetTopToolbar(
                budgets: budgets,
                selectedBudgetID: $selectedBudgetID,
                onCreateBudget: onCreateBudget
            )

            ToolbarItem(placement: .primaryAction) {
                Button {
                    isCreatingTransaction = true
                } label: {
                    Image(systemName: "plus")
                }
                .help("Add Transaction")
                .disabled(budget.categories.isEmpty)
            }
        }
        .sheet(isPresented: $isCreatingTransaction) {
            CreateTransactionView(
                categories: budget.categories,
                onSave: { draft in
                    onAddTransaction(draft)
                    isCreatingTransaction = false
                },
                onCancel: {
                    isCreatingTransaction = false
                }
            )
            .frame(minWidth: 420)
        }
    }
}

private struct TransactionRowView: View {
    let transaction: BudgetTransaction

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(transaction.title)
                    .font(.body)

                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(transaction.amount.formatted())
                .font(.body)
                .fontWeight(.semibold)
                .monospacedDigit()
        }
        .padding(.vertical, 4)
    }

    private var summary: Swift.String {
        var parts = [
            transaction.formattedDate,
            transaction.categoryTitle,
            transaction.categoryType.title
        ]

        if !transaction.description.isEmpty {
            parts.append(transaction.description)
        }

        return parts.joined(separator: " | ")
    }
}
