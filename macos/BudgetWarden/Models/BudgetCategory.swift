import Foundation

struct BudgetCategory: Identifiable {
    let id: Swift.String
    let coreID: Int
    let title: Swift.String
    let amountPlanned: UInt64
    let amountActual: UInt64
    let amountAccumulated: UInt64
    let type: BudgetCategoryType
    let transactions: [BudgetTransaction]
}

struct BudgetTransaction: Identifiable {
    let id: Swift.String
    let coreID: Int
    let title: Swift.String
    let description: Swift.String
    let date: BWDate
    let amount: UInt64
    let categoryID: Int
    let categoryTitle: Swift.String
    let categoryType: BudgetCategoryType

    var formattedDate: Swift.String {
        Swift.String(format: "%04d-%02d-%02d", date.year, date.month, date.day)
    }
}
