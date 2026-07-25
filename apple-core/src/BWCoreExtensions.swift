/*
 * Budget Warden
 * Copyright (c) 2026 Lazarov & Co EOOD
 * Author: Nikola Lazarov
 *
 * Licensed under the Source-Available Educational License.
 * See the LICENSE file in the project root for full terms.
 */

@_exported import BWCore
import Foundation

extension BWBudget: @retroactive Identifiable {}
extension BWCategory: @retroactive Identifiable {}
extension BWTransaction: @retroactive Identifiable {}

public extension BWBudget {
    func orderedCategories(for type: BWCategoryType? = nil) -> [BWCategory] {
        orderedCategories(categoryType: type)
    }
}

public extension BWDate {
    init(_ date: Date, calendar: Calendar = .current) {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(
            year: Int32(components.year ?? 1970),
            month: Int32(components.month ?? 1),
            day: Int32(components.day ?? 1)
        )
    }

    var foundationDate: Date {
        Calendar.current.date(from: DateComponents(
            year: Int(year),
            month: Int(month),
            day: Int(day)
        )) ?? .distantPast
    }
}

extension BWDate: @retroactive Comparable {
    public static func < (lhs: BWDate, rhs: BWDate) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }
}

extension BWMoneyAmount: @retroactive Comparable {
    public static func < (lhs: BWMoneyAmount, rhs: BWMoneyAmount) -> Bool {
        lhs.value < rhs.value
    }

    public var unsignedValue: UInt64 {
        UInt64(clamping: value)
    }

    public var moneyInputText: String {
        (try? BWCore.formatMoneyInput(amount: self))
            ?? unsignedValue.moneyInputText
    }

    public func formattedMoneyAmount(currency: BWCurrency) -> String {
        unsignedValue.formattedMoneyAmount(currency: currency)
    }
}
