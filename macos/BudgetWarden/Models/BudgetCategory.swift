import Foundation

struct BudgetCategory: Identifiable {
    let id: Swift.String
    let coreID: Int
    let title: Swift.String
    let amountPlanned: UInt64
    let amountActual: UInt64
    let amountAccumulated: UInt64
    let type: BudgetCategoryType
}
