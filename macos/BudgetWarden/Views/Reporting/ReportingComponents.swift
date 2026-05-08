import SwiftUI

struct ReportChartSection<Content: View>: View {
    let title: Swift.String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline)
                .fontWeight(.semibold)

            content
                .padding(10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Color(nsColor: .quaternarySystemFill))
                .clipShape(.rect(cornerRadius: 8, style: .continuous))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct ReportMetricView: View {
    let title: Swift.String
    let valueText: Swift.String
    var detail: Swift.String?
    var valueColor: Color = .primary

    init(
        title: Swift.String,
        value: UInt64,
        currency: AppCurrency,
        valueColor: Color = .primary,
        detail: Swift.String? = nil
    ) {
        self.title = title
        self.valueText = value.formattedMoneyAmount(currency: currency)
        self.detail = detail
        self.valueColor = valueColor
    }

    init(
        title: Swift.String,
        signedValue: Int64,
        currency: AppCurrency,
        valueColor: Color = .primary,
        detail: Swift.String? = nil
    ) {
        self.title = title
        let prefix = signedValue < 0 ? "-" : ""
        self.valueText = "\(prefix)\(UInt64(signedValue.magnitude).formattedMoneyAmount(currency: currency))"
        self.detail = detail
        self.valueColor = valueColor
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(valueText)
                .font(.title3)
                .fontWeight(.semibold)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .foregroundStyle(valueColor)

            if let detail {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .quaternarySystemFill))
        .clipShape(.rect(cornerRadius: 8, style: .continuous))
        .accessibilityIdentifier("reporting-metric-\(title.accessibilityIdentifierComponent)")
    }
}

private extension Swift.String {
    var accessibilityIdentifierComponent: Swift.String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalars = unicodeScalars.map { scalar in
            allowed.contains(scalar) ? Character(scalar) : "-"
        }

        return Swift.String(scalars)
    }
}

struct ChartLegendSwatch: View {
    let title: Swift.String
    let tint: Color

    var body: some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2)
                .fill(tint)
                .frame(width: 8, height: 8)

            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

struct AllocationBreakdownLegendRow: View {
    let segment: AllocationBreakdownSegment
    let total: UInt64
    let currency: AppCurrency

    private var percentText: Swift.String {
        guard total > 0 else {
            return "0%"
        }

        let percent = Double(segment.amount) / Double(total)
        return percent.formatted(.percent.precision(.fractionLength(0...1)))
    }

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2)
                .fill(segment.tint)
                .frame(width: 8, height: 8)

            Text(segment.title)
                .font(.caption)

            Spacer()

            Text(segment.amount.formattedMoneyAmount(currency: currency))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            Text(percentText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 42, alignment: .trailing)
        }
    }
}
