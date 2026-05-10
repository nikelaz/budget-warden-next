import Foundation

struct BudgetRow: Identifiable, Sendable {
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

    var coreField: BWCategoryAmountField {
        switch self {
        case .planned:
            return BW_CATEGORY_AMOUNT_PLANNED
        case .actual:
            return BW_CATEGORY_AMOUNT_ACTUAL
        case .accumulated:
            return BW_CATEGORY_AMOUNT_ACCUMULATED
        }
    }
}

extension BWString {
    nonisolated func swiftString(default fallback: Swift.String = "") -> Swift.String {
        data.map { Swift.String(cString: $0) } ?? fallback
    }
}

extension Optional where Wrapped == UnsafePointer<CChar> {
    nonisolated func swiftString(default fallback: Swift.String = "") -> Swift.String {
        map { Swift.String(cString: $0) } ?? fallback
    }
}

extension BWDate {
    var formattedDate: Swift.String {
        Swift.String(format: "%04d-%02d-%02d", year, month, day)
    }
}

extension BWCategoryView {
    func amount(_ field: CategoryAmountField) -> UInt64 {
        switch field {
        case .planned:
            return amount_planned
        case .actual:
            return amount_actual
        case .accumulated:
            return amount_accumulated
        }
    }

    var type: BudgetCategoryType? {
        BudgetCategoryType(coreType: category_type)
    }
}

extension BWTransactionView {
    var categoryID: Int {
        Int(category_id)
    }

    var categoryType: BudgetCategoryType? {
        BudgetCategoryType(coreType: category_type)
    }
}
