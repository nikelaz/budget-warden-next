import Foundation

extension UInt64 {
    func formattedMoneyAmount(currency: AppCurrency) -> Swift.String {
        let formatter = NumberFormatter()
        formatter.locale = .current
        formatter.numberStyle = .currency
        formatter.currencyCode = currency.rawValue
        formatter.currencySymbol = currency.symbol
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2

        return formatter.string(from: majorAmountNumber) ?? "\(formattedMajorAmount) \(currency.symbol)"
    }

    private var formattedMajorAmount: Swift.String {
        let majorAmount = self / 100
        let minorAmount = self % 100
        let minorText = minorAmount < 10 ? "0\(minorAmount)" : "\(minorAmount)"
        let separator = Locale.current.decimalSeparator ?? "."

        return "\(majorAmount.formatted(.number.grouping(.automatic)))\(separator)\(minorText)"
    }

    private var majorAmountNumber: NSDecimalNumber {
        let majorAmount = Decimal(self / 100)
        let minorAmount = Decimal(self % 100) / 100
        return NSDecimalNumber(decimal: majorAmount + minorAmount)
    }

    var moneyAmountInputText: Swift.String {
        let majorAmount = self / 100
        let minorAmount = self % 100
        let minorText = minorAmount < 10 ? "0\(minorAmount)" : "\(minorAmount)"
        let separator = Locale.current.decimalSeparator ?? "."

        return "\(majorAmount)\(separator)\(minorText)"
    }

    static func parseMoneyAmount(_ text: Swift.String, emptyValue: UInt64? = nil) -> UInt64? {
        let trimmedAmount = text.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedAmount.isEmpty else {
            return emptyValue
        }

        let normalizedAmount = trimmedAmount.replacingOccurrences(of: ",", with: ".")
        let parts = normalizedAmount.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)

        guard parts.count <= 2 else {
            return nil
        }

        let wholePart = parts[0]
        let fractionPart = parts.count == 2 ? parts[1] : nil

        guard !wholePart.isEmpty || fractionPart != nil else {
            return nil
        }

        guard wholePart.allSatisfy(\.isNumber) else {
            return nil
        }

        if let fractionPart {
            guard
                (1...2).contains(fractionPart.count),
                fractionPart.allSatisfy(\.isNumber)
            else {
                return nil
            }
        }

        let wholeAmount = wholePart.isEmpty ? 0 : UInt64(wholePart)

        guard let wholeAmount else {
            return nil
        }

        let scaledWholeAmount = wholeAmount.multipliedReportingOverflow(by: 100)

        guard !scaledWholeAmount.overflow else {
            return nil
        }

        let scaledFractionAmount: UInt64

        if let fractionPart {
            guard let fractionAmount = UInt64(fractionPart) else {
                return nil
            }

            scaledFractionAmount = fractionPart.count == 1 ? fractionAmount * 10 : fractionAmount
        } else {
            scaledFractionAmount = 0
        }

        let scaledAmount = scaledWholeAmount.partialValue.addingReportingOverflow(scaledFractionAmount)

        guard !scaledAmount.overflow else {
            return nil
        }

        return scaledAmount.partialValue
    }
}
