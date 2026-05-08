import Foundation

struct BudgetRow: Identifiable {
    let url: URL
    let coreID: Int
    let title: Swift.String

    var id: Swift.String {
        url.standardizedFileURL.path
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

enum CategoryAmountField {
    case planned
    case actual
    case accumulated
}

extension BWString {
    func swiftString(default fallback: Swift.String = "") -> Swift.String {
        data.map { Swift.String(cString: $0) } ?? fallback
    }
}

extension BWDate {
    var formattedDate: Swift.String {
        Swift.String(format: "%04d-%02d-%02d", year, month, day)
    }
}
