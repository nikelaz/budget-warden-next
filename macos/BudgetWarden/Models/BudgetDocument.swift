import Foundation

struct BudgetDocument: Identifiable {
    let id: Int
    let url: URL
    let title: Swift.String
    let categories: [BudgetCategory]

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
