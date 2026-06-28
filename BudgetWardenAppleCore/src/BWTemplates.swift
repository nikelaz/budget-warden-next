import Foundation

public enum BWTemplateSelection: Hashable, Sendable {
    case basic
    case blank
    case previous(URL)
}

public struct BWTemplate {
    public static func basicBudget(title: String) -> BWBudget {
        BWBudget(
            title: title,
            categories: [
                BWCategory(title: "Salary", amountPlanned: 480000, categoryType: .income),

                BWCategory(ordinal: 0, title: "Fun & Entertainment", amountPlanned: 20000, categoryType: .expenses),
                BWCategory(ordinal: 1, title: "Health & Fitness", amountPlanned: 15000, categoryType: .expenses),
                BWCategory(ordinal: 2, title: "Giving", amountPlanned: 24000, categoryType: .expenses),
                BWCategory(ordinal: 3, title: "Utilities", amountPlanned: 28000, categoryType: .expenses),
                BWCategory(ordinal: 4, title: "Miscellaneous", amountPlanned: 15000, categoryType: .expenses),
                BWCategory(ordinal: 5, title: "Insurance", amountPlanned: 30000, categoryType: .expenses),
                BWCategory(ordinal: 6, title: "Housing", amountPlanned: 120000, categoryType: .expenses),
                BWCategory(ordinal: 7, title: "Food", amountPlanned: 64000, categoryType: .expenses),
                BWCategory(ordinal: 8, title: "Personal Care", amountPlanned: 18000, categoryType: .expenses),
                BWCategory(ordinal: 9, title: "Transportation", amountPlanned: 24000, categoryType: .expenses),

                BWCategory(ordinal: 0, title: "Emergency Fund", amountPlanned: 50000, categoryType: .savings),
                BWCategory(ordinal: 1, title: "Retirement", amountPlanned: 72000, categoryType: .savings)
            ]
        )
    }
}
