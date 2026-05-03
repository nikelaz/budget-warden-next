import Foundation

enum AppCurrency: Swift.String, CaseIterable, Identifiable {
    case eur = "EUR"
    case usd = "USD"
    case gbp = "GBP"
    case bgn = "BGN"
    case chf = "CHF"
    case jpy = "JPY"

    var id: Swift.String {
        rawValue
    }

    var title: Swift.String {
        switch self {
        case .eur:
            return "Euro"
        case .usd:
            return "US Dollar"
        case .gbp:
            return "British Pound"
        case .bgn:
            return "Bulgarian Lev"
        case .chf:
            return "Swiss Franc"
        case .jpy:
            return "Japanese Yen"
        }
    }

    var symbol: Swift.String {
        switch self {
        case .eur:
            return "€"
        case .usd:
            return "$"
        case .gbp:
            return "£"
        case .bgn:
            return "лв"
        case .chf:
            return "CHF"
        case .jpy:
            return "¥"
        }
    }

    var displayName: Swift.String {
        "\(title) (\(symbol))"
    }
}
