import Foundation

nonisolated struct AppCurrency: RawRepresentable, CaseIterable, Hashable, Identifiable {
    let rawValue: Swift.String

    static var allCases: [AppCurrency] {
        Locale.Currency.isoCurrencies
            .map(AppCurrency.init(currency:))
            .sorted { firstCurrency, secondCurrency in
                firstCurrency.sortTitle.localizedStandardCompare(secondCurrency.sortTitle) == .orderedAscending
            }
    }

    static let eur = AppCurrency(rawValue: "EUR")!

    init?(rawValue: Swift.String) {
        let normalizedRawValue = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased(with: Locale(identifier: "en_US_POSIX"))

        guard Self.availableCurrencyCodes.contains(normalizedRawValue) else {
            return nil
        }

        self.rawValue = normalizedRawValue
    }

    var id: Swift.String {
        rawValue
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
