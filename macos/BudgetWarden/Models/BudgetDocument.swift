import Foundation

struct BudgetDocument: Identifiable {
    let id: URL
    let url: URL
    let title: Swift.String
    let periodStart: BWDate
    let periodEnd: BWDate
    let categories: [BudgetCategory]

    var period: Swift.String {
        "\(Self.format(periodStart)) - \(Self.format(periodEnd))"
    }

    private static func format(_ date: BWDate) -> Swift.String {
        Swift.String(format: "%04d-%02d-%02d", date.year, date.month, date.day)
    }

    func categories(for type: BudgetCategoryType) -> [BudgetCategory] {
        categories.filter { $0.type == type }
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
