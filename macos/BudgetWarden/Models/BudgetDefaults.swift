import Foundation

struct BudgetDefaults {
    let title: Swift.String

    static func currentMonth(calendar: Calendar = .current, now: Date = Date()) -> BudgetDefaults {
        let components = calendar.dateComponents([.year, .month], from: now)
        let titleDate = calendar.date(from: components) ?? now

        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "LLLL yyyy"

        return BudgetDefaults(title: formatter.string(from: titleDate))
    }
}
