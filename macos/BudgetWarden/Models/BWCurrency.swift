/* 
 * Budget Warden
 * Copyright (c) 2026 Lazarov & Co EOOD
 * Author: Nikola Lazarov
 *
 * Licensed under the Source-Available Educational License. 
 * See the LICENSE file in the project root for full terms.
 *
 */

import Foundation

nonisolated struct BWCurrency: RawRepresentable, CaseIterable, Hashable {
    let rawValue: Swift.String

    static let allCases: [BWCurrency] =
        Locale.Currency.isoCurrencies
            .map(BWCurrency.init(currency:))
            .sorted { firstCurrency, secondCurrency in
                firstCurrency.sortTitle.localizedStandardCompare(secondCurrency.sortTitle) == .orderedAscending
            }

    static var defaultCurrency: BWCurrency {
        defaultCurrency(for: .current)
    }

    static func defaultCurrency(for locale: Locale) -> BWCurrency {
        locale.currency
            .flatMap { BWCurrency(rawValue: $0.identifier) } ??
            BWCurrency(rawValue: "USD")!
    }

    init?(rawValue: Swift.String) {
        let normalizedRawValue = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased(with: Locale(identifier: "en_US_POSIX"))

        guard Self.availableCurrencyCodes.contains(normalizedRawValue) else {
            return nil
        }

        self.rawValue = normalizedRawValue
    }

    var title: Swift.String {
        Locale.current.localizedString(forCurrencyCode: rawValue) ?? rawValue
    }

    var symbol: Swift.String {
        let formatter = NumberFormatter()
        formatter.locale = .current
        formatter.numberStyle = .currency
        formatter.currencyCode = rawValue

        guard
            let currencySymbol = formatter.currencySymbol,
            !currencySymbol.isEmpty,
            currencySymbol != "¤"
        else {
            return rawValue
        }

        return currencySymbol
    }

    var displayName: Swift.String {
        symbol == rawValue ? "\(title) (\(rawValue))" : "\(title) (\(rawValue), \(symbol))"
    }

    private static let availableCurrencyCodes = Set(Locale.Currency.isoCurrencies.map(\.identifier))

    private init(currency: Locale.Currency) {
        rawValue = currency.identifier
    }

    private var sortTitle: Swift.String {
        "\(title) \(rawValue)"
    }
}
