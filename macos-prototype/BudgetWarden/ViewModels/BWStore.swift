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
import Combine

@MainActor
final class BWStore: ObservableObject {
    @Published private(set) var budgetRows: [BudgetRow] = []
    @Published var externalBudgetURL: URL?
    @Published var selectedBudgetURL: URL?
    @Published var presentedError: String?
    @Published var budgetsLoaded: Bool = false
    @Published var selectedCurrency: AppCurrency {
        didSet {
            UserDefaults.standard.set(selectedCurrency.rawValue, forKey: Self.selectedCurrencyKey)
        }
    }

    private var pendingDraft: BudgetDraft?
    private let vault: BWBudgetVault
    private let fileManager = FileManager.default
    private var loadedBudgetURL: URL?
    private var loadedBudget: Budget?
    private var externalBudgetRow: BudgetRow?
    private var isLoadingBudgets = false
    @Published private var revision = 0
    private static let selectedCurrencyKey = "SelectedCurrency"
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return encoder
    }()

    init(vault: BWBudgetVault? = nil) {
        let resolvedVault = vault ?? BWBudgetVault.shared
        self.vault = resolvedVault
        let savedCurrency = UserDefaults.standard.string(forKey: Self.selectedCurrencyKey)
            .flatMap(AppCurrency.init(rawValue:))
        _selectedCurrency = Published(initialValue: savedCurrency ?? .defaultCurrency)
    }

    var budgets: [BudgetRow] {
        budgetRows
    }

    var availableBudgetRows: [BudgetRow] {
        guard let externalBudgetURL, let externalBudgetRow else {
            return budgetRows
        }

        if budgetRows.contains(where: { sameFile($0.url, externalBudgetURL) }) {
            return budgetRows
        }

        return budgetRows + [externalBudgetRow]
    }

    var selectedBudgetRow: BudgetRow? {
        if let selectedBudgetURL, let row = metadataRow(for: selectedBudgetURL) {
            return row
        }

        return budgetRows.first ?? externalBudgetRow
    }

    var configuredLocalVaultParentURL: URL? {
        vault.configuredLocalParentURL()
    }

    func selectBudget(_ budget: BudgetRow) {
        selectedBudgetURL = budget.url
        loadSelectedBudget()
    }

    func cancelVaultSetup() {
        pendingDraft = nil
    }

    func loadBudgets() {
        if budgetsLoaded || isLoadingBudgets {
            return
        }

        let vaultURL: URL

        do {
            vaultURL = try vault.resolveVaultURL()
        } catch BWError.vaultNotConfigured {
            releaseLoadedBudget()
            budgetRows = []
            selectedBudgetURL = externalBudgetURL
            loadSelectedBudget()
            budgetsLoaded = true
            return
        } catch {
            presentedError = error.localizedDescription
            return
        }

        isLoadingBudgets = true
        applyLoadedBudgets(
            Result { try BWBudgetVault.loadBudgetRows(in: vaultURL) },
            selectedBudgetURL: selectedBudgetURL,
            externalBudgetURL: externalBudgetURL,
            externalBudgetRow: externalBudgetRow
        )
    }

    private func applyLoadedBudgets(
        _ result: Result<[BudgetRow], Error>,
        selectedBudgetURL loadingSelectedBudgetURL: URL?,
        externalBudgetURL loadingExternalBudgetURL: URL?,
        externalBudgetRow loadingExternalBudgetRow: BudgetRow?
    ) {
        defer {
            isLoadingBudgets = false
        }

        switch result {
        case .success(let loadedRows):
            budgetRows = loadedRows

            if !Self.hasAvailableBudget(
                at: loadingSelectedBudgetURL,
                budgetRows: loadedRows,
                externalBudgetURL: loadingExternalBudgetURL,
                externalBudgetRow: loadingExternalBudgetRow
            ) {
                selectedBudgetURL = externalBudgetURL ?? loadedRows.first?.url
            }

            loadSelectedBudget()
            budgetsLoaded = true
        case .failure(BWError.vaultNotConfigured):
            releaseLoadedBudget()
            budgetRows = []
            selectedBudgetURL = externalBudgetURL
            loadSelectedBudget()
            budgetsLoaded = true
        case .failure(let error):
            presentedError = error.localizedDescription
        }
    }

    @discardableResult
    func createBudget(_ draft: BudgetDraft) -> Bool {
        pendingDraft = draft

        do {
            _ = try vault.resolveVaultURL()
            savePendingBudget()
            return true
        } catch BWError.vaultNotConfigured {
            return false
        } catch {
            presentedError = error.localizedDescription
            return false
        }
    }

    func configureVault(preferICloud: Bool) {
        guard let parentURL = vault.selectVaultParent(preferICloud: preferICloud) else {
            return
        }

        configureVault(parentURL: parentURL)
    }

    func configureVault(parentURL: URL) {
        do {
            try vault.configureVault(parentURL: parentURL)

            if pendingDraft == nil {
                loadBudgets()
            } else {
                savePendingBudget()
            }
        } catch {
            presentedError = error.localizedDescription
        }
    }

    @discardableResult
    func openBudgetInPlace() -> Bool {
        guard let url = vault.selectBudgetFile() else {
            return false
        }

        do {
            let key = budgetKey(for: url)

            if let vaultBudget = budgetRows.first(where: { sameFile($0.url, url) }) {
                externalBudgetURL = nil
                externalBudgetRow = nil
                selectedBudgetURL = vaultBudget.url
                loadSelectedBudget()
                return true
            }

            let budget = try openBudget(at: url)
            setLoadedBudget(budget, for: key)
            externalBudgetRow = row(from: budget, for: key)
            externalBudgetURL = key
            selectedBudgetURL = key
            revision += 1
            return true
        } catch {
            presentedError = error.localizedDescription
            return false
        }
    }

    func addCategory(title: String, amountPlanned: UInt64, amountAccumulated: UInt64, type: BudgetCategoryType) {
        mutateSelectedBudget { budget in
            try budget.addCategory(title: title, amountPlanned: amountPlanned, amountAccumulated: amountAccumulated, type: type)
        }
    }

    func updateCategory(_ update: CategoryUpdate) {
        mutateSelectedBudget { budget in
            try budget.updateCategory(update)
        }
    }

    func removeCategory(categoryID: Int) {
        mutateSelectedBudget { budget in
            try budget.removeCategory(id: categoryID)
        }
    }

    func reorderCategories(type: BudgetCategoryType, orderedCategoryIDs: [Int]) {
        mutateSelectedBudget { budget in
            budget.reorderCategories(type: type, orderedCategoryIDs: orderedCategoryIDs)
        }
    }

    func addTransaction(_ draft: TransactionDraft) {
        mutateSelectedBudget { budget in
            try budget.addTransaction(draft)
        }
    }

    func updateTransaction(_ update: TransactionUpdate) {
        mutateSelectedBudget { budget in
            try budget.updateTransaction(update)
        }
    }

    func removeTransaction(transactionID: Int) {
        mutateSelectedBudget { budget in
            try budget.removeTransaction(id: transactionID)
        }
    }

    func removeBudget(url: URL) {
        do {
            let key = budgetKey(for: url)
            let wasSelected = selectedBudgetURL.map { sameFile($0, key) } ?? false
            let wasExternal = externalBudgetURL.map { sameFile($0, key) } ?? false

            try accessBudget(key) {
                try removeFile(at: key)
            }

            if wasExternal {
                if loadedBudgetURL.map({ sameFile($0, key) }) == true {
                    releaseLoadedBudget()
                }

                externalBudgetURL = nil
                externalBudgetRow = nil
            }

            budgetRows = try loadVaultBudgets()

            if wasSelected || !hasAvailableBudget(at: selectedBudgetURL) {
                selectedBudgetURL = externalBudgetURL ?? budgetRows.first?.url
                loadSelectedBudget()
            }

            revision += 1
        } catch {
            presentedError = error.localizedDescription
        }
    }

    func categoryIDs(for type: BudgetCategoryType, in url: URL? = nil) -> [Int] {
        budget(for: url)?.categoryIDs(for: type) ?? []
    }

    func categoryIDs(in url: URL? = nil) -> [Int] {
        budget(for: url)?.categoryIDs() ?? []
    }

    func transactionIDs(in url: URL? = nil) -> [Int] {
        budget(for: url)?.transactionIDs() ?? []
    }

    func hasCategories(in url: URL? = nil) -> Bool {
        !categoryIDs(in: url).isEmpty
    }

    func categoryTotal(type: BudgetCategoryType, field: CategoryAmountField, in url: URL? = nil) -> UInt64 {
        budget(for: url)?.categoryTotal(type: type, field: field) ?? 0
    }

    func category(_ categoryID: Int, in url: URL? = nil) -> BWCategoryView? {
        budget(for: url)?.categoryView(id: categoryID)
    }

    func transaction(_ transactionID: Int, in url: URL? = nil) -> BWTransactionView? {
        budget(for: url)?.transactionView(id: transactionID)
    }

    private func savePendingBudget() {
        guard let draft = pendingDraft else {
            return
        }

        do {
            let savedURL = try createBudgetFile(draft)
            pendingDraft = nil
            budgetRows = try loadVaultBudgets()
            externalBudgetURL = nil
            selectedBudgetURL = savedURL
            revision += 1
        } catch {
            presentedError = error.localizedDescription
        }
    }

    private func mutateSelectedBudget(_ mutation: (inout Budget) throws -> Void) {
        guard let selectedBudgetURL, var budget = budget(for: selectedBudgetURL) else {
            return
        }

        do {
            try mutation(&budget)

            try accessBudget(selectedBudgetURL) {
                try writeBudget(budget, to: selectedBudgetURL)
            }

            setLoadedBudget(budget, for: selectedBudgetURL)
            refreshRow(for: selectedBudgetURL)
            revision += 1
        } catch {
            presentedError = error.localizedDescription
        }
    }

    private func loadVaultBudgets() throws -> [BudgetRow] {
        try BWBudgetVault.loadBudgetRows(in: vault.resolveVaultURL())
    }

    private func createBudgetFile(_ draft: BudgetDraft) throws -> URL {
        let vaultURL = try vault.resolveVaultURL()

        return try vault.accessVault {
            let uniqueBudget = vault.uniqueBudgetLocation(for: draft.title, in: vaultURL)
            var budget: Budget

            if let templateURL = draft.templateURL {
                budget = try readBudget(at: templateURL)
                budget.title = uniqueBudget.title
            } else {
                budget = Budget(title: uniqueBudget.title)
            }

            budget.id = try nextBudgetID(in: vaultURL)
            try writeBudget(budget, to: uniqueBudget.url)
            setLoadedBudget(budget, for: uniqueBudget.url)
            return uniqueBudget.url
        }
    }

    private func openBudget(at url: URL) throws -> Budget {
        try accessBudget(url) {
            try readBudget(at: url)
        }
    }

    private func readBudget(at url: URL) throws -> Budget {
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(Budget.self, from: data)
        } catch {
            throw BWError.budgetReadFailed(url)
        }
    }

    private func writeBudget(_ budget: Budget, to url: URL) throws {
        do {
            let data = try Self.encoder.encode(budget)
            try data.write(to: url, options: .atomic)
        } catch {
            throw BWError.jsonCreationFailed
        }
    }

    private func setLoadedBudget(_ budget: Budget, for url: URL) {
        loadedBudgetURL = budgetKey(for: url)
        loadedBudget = budget
    }

    private func releaseLoadedBudget() {
        loadedBudgetURL = nil
        loadedBudget = nil
    }

    private func budget(for url: URL?) -> Budget? {
        guard
            let url = url ?? selectedBudgetURL,
            let loadedBudgetURL,
            sameFile(loadedBudgetURL, url)
        else {
            return nil
        }

        return loadedBudget
    }

    private func loadSelectedBudget() {
        guard let selectedBudgetURL else {
            releaseLoadedBudget()
            revision += 1
            return
        }

        if loadedBudgetURL.map({ sameFile($0, selectedBudgetURL) }) == true {
            revision += 1
            return
        }

        do {
            setLoadedBudget(try openBudget(at: selectedBudgetURL), for: selectedBudgetURL)
            revision += 1
        } catch {
            presentedError = error.localizedDescription
        }
    }

    private func row(from budget: Budget, for url: URL) -> BudgetRow {
        let key = budgetKey(for: url)
        return BudgetRow(
            url: key,
            budgetID: budget.id,
            title: budget.title.isEmpty ? key.deletingPathExtension().lastPathComponent : budget.title
        )
    }

    private func metadataRow(for url: URL) -> BudgetRow? {
        let key = budgetKey(for: url)

        if let row = budgetRows.first(where: { sameFile($0.url, key) }) {
            return row
        }

        if externalBudgetURL.map({ sameFile($0, key) }) == true {
            return externalBudgetRow
        }

        return nil
    }

    private func refreshRow(for url: URL) {
        guard let budget = budget(for: url) else {
            return
        }

        let updated = row(from: budget, for: url)

        if let index = budgetRows.firstIndex(where: { sameFile($0.url, url) }) {
            budgetRows[index] = updated
        } else if externalBudgetURL.map({ sameFile($0, url) }) == true {
            externalBudgetRow = updated
        }
    }

    private func sameFile(_ lhs: URL, _ rhs: URL) -> Bool {
        budgetKey(for: lhs) == budgetKey(for: rhs)
    }

    private func budgetKey(for url: URL) -> URL {
        url.standardizedFileURL
    }

    private func hasAvailableBudget(at url: URL?) -> Bool {
        guard let url else {
            return false
        }

        return availableBudgetRows.contains { sameFile($0.url, url) }
    }

    private func removeFile(at url: URL) throws {
        do {
            var trashedURL: NSURL?
            try fileManager.trashItem(at: url, resultingItemURL: &trashedURL)
        } catch {
            throw BWError.budgetRemoveFailed(url)
        }
    }

    private func nextBudgetID(in vaultURL: URL) throws -> Int {
        let maxID = try vault.budgetFileURLs(in: vaultURL)
            .compactMap { url -> Int? in
                try? readBudget(at: url).id
            }
            .max() ?? 0

        return maxID + 1
    }

    private func accessBudget<T>(_ url: URL, operation: () throws -> T) throws -> T {
        if vault.isBudgetInConfiguredVault(url) {
            return try vault.accessVault(operation)
        }

        return try BWBudgetVault.accessSecurityScopedResource(url, operation: operation)
    }

    nonisolated private static func hasAvailableBudget(
        at url: URL?,
        budgetRows: [BudgetRow],
        externalBudgetURL: URL?,
        externalBudgetRow: BudgetRow?
    ) -> Bool {
        guard let url else {
            return false
        }

        let key = url.standardizedFileURL

        if budgetRows.contains(where: { $0.url.standardizedFileURL == key }) {
            return true
        }

        guard externalBudgetURL != nil, let externalBudgetRow else {
            return false
        }

        return externalBudgetRow.url.standardizedFileURL == key
    }
}
