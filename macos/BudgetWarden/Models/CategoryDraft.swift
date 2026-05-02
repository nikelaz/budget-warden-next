import Foundation

struct CategoryDraft {
    let title: Swift.String
    let amountPlanned: UInt64
    let type: BudgetCategoryType
}

struct TransactionDraft {
    let categoryID: Int
    let title: Swift.String
    let description: Swift.String
    let date: BWDate
    let amount: UInt64
}
