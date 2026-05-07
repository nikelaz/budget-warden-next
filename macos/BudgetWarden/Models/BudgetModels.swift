import Foundation

struct BudgetDocument: Identifiable {
    let coreID: Int
    let url: URL
    let title: Swift.String
    let categories: [BudgetCategory]

    var id: Swift.String {
        url.standardizedFileURL.path
    }

    func categories(for type: BudgetCategoryType) -> [BudgetCategory] {
        categories
            .filter { $0.type == type }
            .sorted {
                if $0.ordinal != $1.ordinal {
                    return $0.ordinal < $1.ordinal
                }

                return $0.coreID < $1.coreID
            }
    }

    var transactions: [BudgetTransaction] {
        categories
            .flatMap(\.transactions)
            .sorted {
                if $0.date.year != $1.date.year {
                    return $0.date.year > $1.date.year
                }

                if $0.date.month != $1.date.month {
                    return $0.date.month > $1.date.month
                }

                if $0.date.day != $1.date.day {
                    return $0.date.day > $1.date.day
                }

                return $0.coreID > $1.coreID
            }
    }
}

struct BudgetCategory: Identifiable {
    let id: Swift.String
    let coreID: Int
    let ordinal: Int
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

enum BudgetCategoryType: CaseIterable, Identifiable {
    case income
    case expenses
    case savings
    case debt

    var id: Self {
        self
    }

    var title: Swift.String {
        switch self {
        case .income:
            return "Income"
        case .expenses:
            return "Expenses"
        case .savings:
            return "Savings"
        case .debt:
            return "Debt"
        }
    }

    var coreType: BWCategoryType {
        switch self {
        case .income:
            return CATEGORY_INCOME
        case .expenses:
            return CATEGORY_EXPENSES
        case .savings:
            return CATEGORY_SAVINGS
        case .debt:
            return CATEGORY_DEBT
        }
    }

    init?(coreType: BWCategoryType) {
        switch coreType {
        case CATEGORY_INCOME:
            self = .income
        case CATEGORY_EXPENSES:
            self = .expenses
        case CATEGORY_SAVINGS:
            self = .savings
        case CATEGORY_DEBT:
            self = .debt
        default:
            return nil
        }
    }
}
