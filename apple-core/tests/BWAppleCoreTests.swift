import Foundation
import Testing
@testable import BWAppleCore

@Suite("Budget Warden Apple Core")
struct BWAppleCoreTests {
    @Test("Legacy migration discovery finds only budget files")
    func legacyMigrationDiscovery() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        try "notes".write(
            to: root.appendingPathComponent("Notes.txt"),
            atomically: true,
            encoding: .utf8
        )
        let hasOnlyNonBudgetFiles = await BWLegacyBudgetMigrator.containsBudgetFiles(
            in: [.init(url: root)]
        )
        #expect(!hasOnlyNonBudgetFiles)

        try "budget".write(
            to: root.appendingPathComponent("Plan.BUDGET"),
            atomically: true,
            encoding: .utf8
        )
        let hasBudgetFiles = await BWLegacyBudgetMigrator.containsBudgetFiles(
            in: [.init(url: root)]
        )
        #expect(hasBudgetFiles)
    }

    @Test("Legacy migration moves local and iCloud budget files")
    func legacyMigrationMovesBudgets() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let localSource = root.appendingPathComponent("Local Vault")
        let cloudSource = root.appendingPathComponent("iCloud Vault")
        let documentsRoot = root.appendingPathComponent("Documents")
        let iCloudDriveRoot = root.appendingPathComponent("iCloud Drive")
        try createDirectory(localSource)
        try createDirectory(cloudSource)
        try "local".write(
            to: localSource.appendingPathComponent("Household.BUDGET"),
            atomically: true,
            encoding: .utf8
        )
        try "cloud".write(
            to: cloudSource.appendingPathComponent("Travel.budget"),
            atomically: true,
            encoding: .utf8
        )
        try "ignore".write(
            to: localSource.appendingPathComponent("Notes.txt"),
            atomically: true,
            encoding: .utf8
        )

        let report = await BWLegacyBudgetMigrator.migrate(
            BWLegacyBudgetMigrationRequest(
                localSources: [.init(url: localSource)],
                localDocumentsRoot: .init(url: documentsRoot),
                iCloudSources: [.init(url: cloudSource)],
                iCloudDriveRoot: .init(url: iCloudDriveRoot)
            )
        )

        #expect(report.failures.isEmpty)
        #expect(report.entries.count == 2)
        #expect(report.entries.allSatisfy { $0.outcome == .moved })
        #expect(!FileManager.default.fileExists(
            atPath: localSource.appendingPathComponent("Household.BUDGET").path
        ))
        #expect(FileManager.default.fileExists(
            atPath: documentsRoot.appendingPathComponent("Budgets/Household.BUDGET").path
        ))
        #expect(FileManager.default.fileExists(
            atPath: iCloudDriveRoot.appendingPathComponent("Budgets/Travel.budget").path
        ))
        #expect(FileManager.default.fileExists(
            atPath: localSource.appendingPathComponent("Notes.txt").path
        ))
    }

    @Test("Legacy migration removes an identical source duplicate")
    func legacyMigrationHandlesIdenticalDestination() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let source = root.appendingPathComponent("Legacy")
        let documentsRoot = root.appendingPathComponent("Documents")
        let destination = documentsRoot.appendingPathComponent("Budgets")
        try createDirectory(source)
        try createDirectory(destination)
        let sourceFile = source.appendingPathComponent("Shared.budget")
        let destinationFile = destination.appendingPathComponent("Shared.budget")
        try "same".write(to: sourceFile, atomically: true, encoding: .utf8)
        try "same".write(to: destinationFile, atomically: true, encoding: .utf8)

        let report = await BWLegacyBudgetMigrator.migrate(
            BWLegacyBudgetMigrationRequest(
                localSources: [.init(url: source)],
                localDocumentsRoot: .init(url: documentsRoot)
            )
        )

        #expect(report.failures.isEmpty)
        #expect(report.entries.count == 1)
        #expect(report.entries.first?.outcome == .alreadyPresent)
        #expect(!FileManager.default.fileExists(atPath: sourceFile.path))
        #expect(try String(contentsOf: destinationFile, encoding: .utf8) == "same")
    }

    @Test("Legacy migration keeps differently named conflicts")
    func legacyMigrationRenamesConflicts() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let source = root.appendingPathComponent("Legacy")
        let documentsRoot = root.appendingPathComponent("Documents")
        let destination = documentsRoot.appendingPathComponent("Budgets")
        try createDirectory(source)
        try createDirectory(destination)
        try "legacy".write(
            to: source.appendingPathComponent("Plan.budget"),
            atomically: true,
            encoding: .utf8
        )
        try "current".write(
            to: destination.appendingPathComponent("Plan.budget"),
            atomically: true,
            encoding: .utf8
        )

        let report = await BWLegacyBudgetMigrator.migrate(
            BWLegacyBudgetMigrationRequest(
                localSources: [
                    .init(url: source),
                    .init(url: source)
                ],
                localDocumentsRoot: .init(url: documentsRoot)
            )
        )

        #expect(report.failures.isEmpty)
        #expect(report.entries.count == 1)
        #expect(report.entries.first?.outcome == .renamed)
        #expect(report.entries.first?.destinationURL.lastPathComponent == "Plan 2.budget")
        #expect(try String(
            contentsOf: destination.appendingPathComponent("Plan.budget"),
            encoding: .utf8
        ) == "current")
        #expect(try String(
            contentsOf: destination.appendingPathComponent("Plan 2.budget"),
            encoding: .utf8
        ) == "legacy")
    }

    @Test("Legacy migration reports unreadable source candidates")
    func legacyMigrationReportsSourceFailure() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let invalidDirectory = root.appendingPathComponent("Not a Directory")
        try "file".write(to: invalidDirectory, atomically: true, encoding: .utf8)

        let report = await BWLegacyBudgetMigrator.migrate(
            BWLegacyBudgetMigrationRequest(
                localSources: [.init(url: invalidDirectory)],
                localDocumentsRoot: .init(url: root.appendingPathComponent("Documents"))
            )
        )

        #expect(report.entries.isEmpty)
        #expect(report.failures.count == 1)
        #expect(!report.isComplete(for: .local))
        #expect(FileManager.default.fileExists(atPath: invalidDirectory.path))
    }

    @Test("Money input parsing handles decimals and rejects invalid values")
    func moneyParsing() {
        #expect(UInt64.parseMoneyAmount("12") == 1_200)
        #expect(UInt64.parseMoneyAmount("12.3") == 1_230)
        #expect(UInt64.parseMoneyAmount(",45") == 45)
        #expect(UInt64.parseMoneyAmount("", emptyValue: 0) == 0)
        #expect(UInt64.parseMoneyAmount("12.345") == nil)
        #expect(UInt64.parseMoneyAmount("abc") == nil)
        #expect(UInt64.parseMoneyAmount("\(UInt64.max)") == nil)
    }

    @Test("Money summing reports overflow")
    func moneySumming() {
        #expect(UInt64.sumMoneyAmounts([100, 200, 300]) == 600)
        #expect(UInt64.sumMoneyAmounts([UInt64.max, 1]) == nil)
    }

    @Test("Date conversion preserves calendar components")
    func dateConversion() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = try #require(calendar.date(from: DateComponents(year: 2026, month: 7, day: 24)))

        let coreDate = BWDate(date, calendar: calendar)

        #expect(coreDate.year == 2026)
        #expect(coreDate.month == 7)
        #expect(coreDate.day == 24)
        #expect(BWDate(year: 2026, month: 7, day: 23) < coreDate)
    }

    @Test("Categories are filtered and ordered by the Rust core")
    func orderedCategories() {
        let budget = makeBudget(categories: [
            makeCategory(title: "Expense 2", type: .expenses, ordinal: 2),
            makeCategory(title: "Income", type: .income, ordinal: 3),
            makeCategory(title: "Expense 1", type: .expenses, ordinal: 1)
        ])

        #expect(budget.orderedCategories().map(\.title) == ["Income", "Expense 1", "Expense 2"])
        #expect(budget.orderedCategories(for: .expenses).map(\.title) == ["Expense 1", "Expense 2"])
    }

    @Test("Reporting summary calculates expected totals")
    func reportingSummary() throws {
        let budget = makeBudget(categories: [
            makeCategory(title: "Income", type: .income, planned: 10_000),
            makeCategory(title: "Expense", type: .expenses, planned: 4_000, actual: 3_000),
            makeCategory(title: "Savings", type: .savings, planned: 2_000)
        ])

        let summary = try BWCore.buildReportingSummary(budget: budget)

        #expect(summary.totals.income.value == 10_000)
        #expect(summary.totals.plannedSpending.value == 4_000)
        #expect(summary.totals.actualSpending.value == 3_000)
        #expect(summary.totals.leftToBudget == 4_000)
        #expect(summary.allocationSegments(amountMode: .planned).count == 2)
    }

    private func makeBudget(categories: [BWCategory]) -> BWBudget {
        var budget = BWBudget.new(title: "Test")
        budget.categories = categories
        return budget
    }

    private func makeCategory(
        title: String,
        type: BWCategoryType,
        ordinal: Int32 = 0,
        planned: Int64 = 0,
        actual: Int64 = 0
    ) -> BWCategory {
        BWCategory(
            id: UUID(),
            ordinal: ordinal,
            title: title,
            amountPlanned: BWMoneyAmount(value: planned),
            amountActual: BWMoneyAmount(value: actual),
            amountAccumulated: BWMoneyAmount(value: 0),
            categoryType: type,
            transactions: []
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("BWAppleCoreTests-\(UUID().uuidString)")
        try createDirectory(url)
        return url
    }

    private func createDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
    }
}
