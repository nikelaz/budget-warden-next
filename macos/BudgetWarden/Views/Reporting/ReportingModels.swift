import SwiftUI

enum ReportingScope {
    case inspector
    case fullPage
}

enum AllocationBreakdownMode: Swift.String, CaseIterable, Identifiable {
    case planned
    case actual

    var id: Self {
        self
    }

    var title: Swift.String {
        switch self {
        case .planned:
            return "Planned"
        case .actual:
            return "Actual"
        }
    }

    var amountField: CategoryAmountField {
        switch self {
        case .planned:
            return .planned
        case .actual:
            return .actual
        }
    }
}

struct OutflowComparisonSegment: Identifiable {
    let rowTitle: Swift.String
    let componentTitle: Swift.String
    let amount: UInt64
    let tint: Color

    var id: Swift.String {
        "\(rowTitle)-\(componentTitle)"
    }
}

struct OutflowComparisonTotal: Identifiable {
    let title: Swift.String
    let amount: UInt64

    var id: Swift.String {
        title
    }
}

struct OutflowComparisonLegendItem: Identifiable {
    let title: Swift.String
    let tint: Color

    var id: Swift.String {
        title
    }
}

struct AllocationBreakdownSegment: Identifiable {
    let title: Swift.String
    let amount: UInt64
    let tint: Color

    var id: Swift.String {
        title
    }
}

extension Array where Element == AllocationBreakdownSegment {
    func total(_ keyPath: KeyPath<AllocationBreakdownSegment, UInt64>) -> UInt64 {
        reduce(0) { $0 + $1[keyPath: keyPath] }
    }
}
