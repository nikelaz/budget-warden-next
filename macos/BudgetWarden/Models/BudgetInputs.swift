import Foundation

struct BudgetDraft {
    let title: Swift.String
    let templateURL: URL?
}

struct CategoryDraft {
    let title: Swift.String
    let amountPlanned: UInt64
    let amountAccumulated: UInt64
    let type: BudgetCategoryType
}

struct CategoryUpdate {
    let categoryID: Int
    let title: Swift.String
    let amountPlanned: UInt64
    let amountAccumulated: UInt64
}

struct TransactionDraft {
    let categoryID: Int
    let title: Swift.String
    let description: Swift.String
    let date: BWDate
    let amount: UInt64
}

struct TransactionUpdate {
    let transactionID: Int
    let categoryID: Int
    let title: Swift.String
    let description: Swift.String
    let date: BWDate
    let amount: UInt64
}
