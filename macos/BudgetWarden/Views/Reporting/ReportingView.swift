import SwiftUI

struct ReportingView: View {
    let budgets: [BudgetDocument]
    let budget: BudgetDocument
    let currency: AppCurrency
    let selectedBudgetURL: URL?
    let onCreateBudget: () -> Void
    let onSelectBudget: (BudgetDocument) -> Void
    let onAddTransaction: (TransactionDraft) -> Void

    @State private var isCreatingTransaction = false

    var body: some View {
        BudgetReportingView(
            budget: budget,
            currency: currency,
            isExpanded: .constant(true),
            scope: .fullPage
        )
        .navigationTitle("Reporting")
        .toolbar {
            ToolbarItemGroup(placement: .principal) {
                Menu {
                    ForEach(budgets) { budget in
                        Button {
                            onSelectBudget(budget)
                        } label: {
                            if selectedBudgetURL?.standardizedFileURL == budget.url.standardizedFileURL {
                                Label(budget.title, systemImage: "checkmark")
                            } else {
                                Text(budget.title)
                            }
                        }
                    }

                    Divider()

                    Button {
                        onCreateBudget()
                    } label: {
                        Label("New Budget", systemImage: "plus")
                    }
                } label: {
                    Text(budget.title)
                }
            }
        }
        .sheet(isPresented: $isCreatingTransaction) {
            CreateTransactionView(
                categories: budget.categories,
                initialCategoryID: nil,
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
