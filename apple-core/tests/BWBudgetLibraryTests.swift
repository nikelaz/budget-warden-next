import BWCore
import Foundation
import Testing
@testable import BWAppleCore

@Suite("Budget library")
struct BWBudgetLibraryTests {
    init() {
        // Already initialized by an earlier test in the same process.
        try? initializeCore(deviceId: UUID())
    }

    @Test("Mutations save straight to the file and report the change")
    @MainActor
    func mutateSavesAndNotifies() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let events = EventLog()
        let library = BWBudgetLibrary(newBudgetDirectory: { root }) { events.append($0) }

        let url = try library.create(BWBudget.new(title: "Trip"), fileName: "Trip.budget")
        let saved = try library.mutate(at: url) { try updateBudgetCurrency(budget: $0, currency: "jpy") }

        #expect(saved.currency == "JPY")
        let reread = try decodeBudget(json: String(contentsOf: url, encoding: .utf8), url: url.path)
        #expect(reread.currency == "JPY")
        #expect(reread.revisionId == saved.revisionId)
        try await Task.sleep(for: .milliseconds(50))
        #expect(events.created == [url])
        #expect(events.changed == [url])
    }

    @Test("Reads come from the cache until the file changes")
    func cacheFollowsTheFile() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = BWBudgetLibrary(newBudgetDirectory: { root }) { _ in }
        let url = try library.create(BWBudget.new(title: "First"), fileName: "Budget.budget")

        #expect(try library.budget(at: url).title == "First")

        // Another writer replaces the file.
        let renamed = try updateBudgetTitle(budget: library.budget(at: url), title: "Second, longer title")
        try encodeBudget(budget: renamed).write(to: url, atomically: true, encoding: .utf8)
        #expect(try library.budget(at: url).title == "Second, longer title")
    }

    @Test("Budgets without a currency use the default")
    func defaultCurrency() throws {
        let library = BWBudgetLibrary(newBudgetDirectory: { nil }) { _ in }
        library.update(open: nil, recent: [], defaultCurrencyCode: "BGN")
        #expect(library.currencyCode(of: BWBudget.new(title: "Old")) == "BGN")
        let priced = try updateBudgetCurrency(budget: BWBudget.new(title: "New"), currency: "EUR")
        #expect(library.currencyCode(of: priced) == "EUR")
    }

    @Test("Revision checks keep a newer save")
    func writeChecksRevision() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = BWBudgetLibrary(newBudgetDirectory: { root }) { _ in }
        let url = try library.create(BWBudget.new(title: "Budget"), fileName: "Budget.budget")
        let stale = try library.budget(at: url)
        try library.mutate(at: url) { try updateBudgetTitle(budget: $0, title: "Renamed") }

        let written = try library.write(
            json: encodeBudget(budget: stale),
            to: url,
            expectedRevisionID: stale.revisionId
        )
        #expect(!written)
        #expect(try library.budget(at: url).title == "Renamed")
    }

    @Test("Deleting forgets the budget and reports it")
    @MainActor
    func deleteReports() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let events = EventLog()
        let library = BWBudgetLibrary(newBudgetDirectory: { root }) { events.append($0) }
        let url = try library.create(BWBudget.new(title: "Budget"), fileName: "Budget.budget")
        #expect(library.knownURLs.count == 1)

        try library.delete(at: url)

        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(library.knownURLs.isEmpty)
        try await Task.sleep(for: .milliseconds(50))
        #expect(events.deleted == [url])
    }

    @Test("Shortcuts IDs carry their budget")
    func shortcutIDs() {
        #expect(BWBudgetReference("file:/a/b.budget") == .file("/a/b.budget"))
        #expect(BWBudgetReference("gdrive:abc") == .googleDrive("abc"))
        #expect(BWBudgetReference("2F1A") == nil)
        #expect(BWBudgetReference.file("/a@b/c.budget").id == "file:/a@b/c.budget")

        let item = BWBudgetItemID(itemID: UUID(), budgetID: "file:/a@b/c.budget")
        #expect(BWBudgetItemID(item.id) == item)
        #expect(BWBudgetItemID("not-a-uuid@file:/x") == nil)
    }

    @Test("Amounts become minor units")
    func minorUnits() throws {
        #expect(try BWIntentMoney.minorUnits(12.5) == 1250)
        #expect(try BWIntentMoney.minorUnits(0) == 0)
        #expect(throws: BWIntentError.self) { try BWIntentMoney.minorUnits(1.005) }
        #expect(throws: BWIntentError.self) { try BWIntentMoney.minorUnits(-1) }
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("BWBudgetLibraryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

@MainActor
private final class EventLog {
    var created: [URL] = []
    var changed: [URL] = []
    var deleted: [URL] = []

    func append(_ event: BWBudgetLibraryEvent) {
        switch event {
        case .created(let url): created.append(url)
        case .changed(let url): changed.append(url)
        case .deleted(let url): deleted.append(url)
        }
    }
}
