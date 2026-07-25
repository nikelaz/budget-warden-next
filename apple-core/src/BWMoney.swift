/*
 * Budget Warden
 * Copyright (c) 2026 Lazarov & Co EOOD
 * Author: Nikola Lazarov
 *
 * Licensed under the Source-Available Educational License.
 * See the LICENSE file in the project root for full terms.
 */

import Foundation

public struct BWCurrency: RawRepresentable, CaseIterable, Hashable, Sendable {
    public let rawValue: String

    public static let allCases = Locale.Currency.isoCurrencies
        .map { BWCurrency(uncheckedRawValue: $0.identifier) }
        .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }

    public static var defaultCurrency: BWCurrency {
        Locale.current.currency
            .flatMap { BWCurrency(rawValue: $0.identifier) }
            ?? BWCurrency(uncheckedRawValue: "USD")
    }

    public init?(rawValue: String) {
        let value = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased(with: Locale(identifier: "en_US_POSIX"))
        guard Locale.Currency.isoCurrencies.contains(where: { $0.identifier == value }) else {
            return nil
        }
        self.rawValue = value
    }

    private init(uncheckedRawValue: String) {
        rawValue = uncheckedRawValue
    }

    public var symbol: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = rawValue
        return formatter.currencySymbol ?? rawValue
    }

    public var displayName: String {
        let title = Locale.current.localizedString(forCurrencyCode: rawValue) ?? rawValue
        return "\(title) (\(rawValue), \(symbol))"
    }
}

public extension UInt64 {
    var moneyInputText: String {
        guard let value = Int64(exactly: self),
              let text = try? BWCore.formatMoneyInput(
                amount: BWMoneyAmount(value: value)
              )
        else {
            return String(format: "%llu.%02llu", self / 100, self % 100)
        }
        return text
    }

    func formattedMoneyAmount(currency: BWCurrency) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currency.rawValue
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        let major = Decimal(self / 100)
        let minor = Decimal(self % 100) / 100
        return formatter.string(from: NSDecimalNumber(decimal: major + minor))
            ?? "\(moneyInputText) \(currency.symbol)"
    }

    static func parseMoneyAmount(_ text: String, emptyValue: UInt64? = nil) -> UInt64? {
        let coreEmptyValue: Int64?
        if let emptyValue {
            guard let value = Int64(exactly: emptyValue) else { return nil }
            coreEmptyValue = value
        } else {
            coreEmptyValue = nil
        }

        return BWCore.parseMoneyAmount(
            text: text,
            emptyValue: coreEmptyValue
        )
        .flatMap { UInt64(exactly: $0.value) }
    }

    static func sumMoneyAmounts(_ amounts: some Sequence<UInt64>) -> UInt64? {
        let values = Array(amounts)
        let coreAmounts = values.compactMap { amount in
            Int64(exactly: amount).map(BWMoneyAmount.init(value:))
        }
        guard coreAmounts.count == values.count else {
            return nil
        }

        return try? UInt64(
            exactly: BWCore.sumMoneyAmounts(amounts: coreAmounts).value
        )
    }
}
