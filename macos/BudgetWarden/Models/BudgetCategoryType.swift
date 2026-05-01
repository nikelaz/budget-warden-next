import Foundation

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

    var coreType: CategoryType {
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

    init?(coreType: CategoryType) {
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
