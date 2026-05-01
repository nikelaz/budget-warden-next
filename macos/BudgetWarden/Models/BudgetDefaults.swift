import Foundation

struct BudgetDefaults {
    let title: Swift.String
    let periodStart: Date
    let periodEnd: Date

    static func currentMonth(calendar: Calendar = .current, now: Date = Date()) -> BudgetDefaults {
        let components = calendar.dateComponents([.year, .month], from: now)
        let periodStart = calendar.date(from: components) ?? now
        let range = calendar.range(of: .day, in: .month, for: periodStart)
        let lastDay = range?.upperBound.advanced(by: -1) ?? 1
        let periodEnd = calendar.date(
            from: DateComponents(
                year: components.year,
                month: components.month,
                day: lastDay
            )
        ) ?? periodStart

        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.dateFormat = "LLLL yyyy"

        return BudgetDefaults(
            title: formatter.string(from: periodStart),
            periodStart: periodStart,
            periodEnd: periodEnd
        )
    }
}
