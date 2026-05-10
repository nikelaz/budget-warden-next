/* 
 * Budget Warden Core
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
    @Published var presentedError: Swift.String?
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
    private var loadedBudget: UnsafeMutablePointer<BWBudget>?
    private var externalBudgetRow: BudgetRow?
    private var isLoadingBudgets = false
    @Published private var revision = 0
    private static let selectedCurrencyKey = "SelectedCurrency"
    private static let jsonArenaCapacity = 1024 * 1024

    init(vault: BWBudgetVault? = nil) {
        let resolvedVault = vault ?? BWBudgetVault.shared
        self.vault = resolvedVault
        let savedCurrency = UserDefaults.standard.string(forKey: Self.selectedCurrencyKey)
            .flatMap(AppCurrency.init(rawValue:))
        _selectedCurrency = Published(initialValue: savedCurrency ?? .defaultCurrency)
    }

    deinit {
        if let pointer = loadedBudget {
            freeBudget(pointer)
        }
    }

    var budgets: [BudgetRow] {
        budgetRows
    }

    var availableBudgetRows: [BudgetRow] {
        guard
            let externalBudgetURL,
            let externalRow = externalBudgetRow
        else {
            return budgetRows
        }

        if budgetRows.contains(where: { sameFile($0.url, externalBudgetURL) }) {
            return budgetRows
        }

        return budgetRows + [externalRow]
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

        let selectedBudgetURL = selectedBudgetURL
        let externalBudgetURL = externalBudgetURL
        let externalBudgetRow = externalBudgetRow

        isLoadingBudgets = true
        Task.detached(priority: .userInitiated) { [weak self, vaultURL, selectedBudgetURL, externalBudgetURL, externalBudgetRow] in
            let result = Result {
                try BWBudgetVault.loadBudgetRows(in: vaultURL)
            }

            await self?.applyLoadedBudgets(
                result,
                selectedBudgetURL: selectedBudgetURL,
                externalBudgetURL: externalBudgetURL,
                externalBudgetRow: externalBudgetRow
            )
        }
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

            let pointer = try openBudget(at: url)
            setLoadedBudget(pointer, for: key)
            externalBudgetRow = row(from: pointer, for: key)
            externalBudgetURL = key
            selectedBudgetURL = key
            revision += 1
            return true
        } catch {
            presentedError = error.localizedDescription
            return false
        }
    }

    func addCategory(
        title: Swift.String,
        amountPlanned: UInt64,
        amountAccumulated: UInt64,
        type: BudgetCategoryType
    ) {
        mutateSelectedBudget(BWError.categoryCreationFailed) { budget in
            title.withCString { title in
                bw_budget_add_category_values(
                    budget,
                    title,
                    amountPlanned,
                    0,
                    amountAccumulated,
                    type.coreType
                )
            }
        }
    }

    func updateCategory(_ update: CategoryUpdate) {
        mutateSelectedBudget(BWError.categorySaveFailed) { budget in
            update.title.withCString { title in
                let coreUpdate = BWCategoryUpdate(
                    title: title,
                    amount_planned: update.amountPlanned,
                    amount_accumulated: update.amountAccumulated
                )

                return bw_budget_update_category(budget, Int32(update.categoryID), coreUpdate)
            }
        }
    }

    func removeCategory(categoryID: Int) {
        mutateSelectedBudget(BWError.categoryNotFound) { budget in
            bw_budget_remove_category(budget, Int32(categoryID))
        }
    }

    func reorderCategories(type: BudgetCategoryType, orderedCategoryIDs: [Int]) {
        mutateSelectedBudget(BWError.categorySaveFailed) { budget in
            let coreCategoryIDs = orderedCategoryIDs.map(Int32.init)
            return coreCategoryIDs.withUnsafeBufferPointer { buffer in
                bw_budget_reorder_categories(budget, type.coreType, buffer.baseAddress, buffer.count)
            }
        }
    }

    func addTransaction(_ draft: TransactionDraft) {
        mutateSelectedBudget(BWError.transactionCreationFailed) { budget in
            draft.title.withCString { title in
                draft.description.withCString { description in
                    bw_budget_add_transaction_values(
                        budget,
                        Int32(draft.categoryID),
                        title,
                        description,
                        draft.date,
                        draft.amount
                    )
                }
            }
        }
    }

    func updateTransaction(_ update: TransactionUpdate) {
        mutateSelectedBudget(BWError.transactionSaveFailed) { budget in
            update.title.withCString { title in
                update.description.withCString { description in
                    let coreUpdate = BWTransactionUpdate(
                        category_id: Int32(update.categoryID),
                        title: title,
                        description: description,
                        date: update.date,
                        amount: update.amount
                    )

                    return bw_budget_update_transaction(budget, Int32(update.transactionID), coreUpdate)
                }
            }
        }
    }

    func removeTransaction(transactionID: Int) {
        mutateSelectedBudget(BWError.transactionNotFound) { budget in
            bw_budget_remove_transaction(budget, Int32(transactionID))
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
        guard
            let url = url ?? selectedBudgetURL,
            let pointer = core(for: url)
        else {
            return []
        }

        return ids { output, capacity in
            bw_budget_category_ids(pointer, type.coreType, output, capacity)
        }
    }

    func categoryIDs(in url: URL? = nil) -> [Int] {
        guard
            let url = url ?? selectedBudgetURL,
            let pointer = core(for: url)
        else {
            return []
        }

        return ids { output, capacity in
            bw_budget_all_category_ids(pointer, output, capacity)
        }
    }

    func transactionIDs(in url: URL? = nil) -> [Int] {
        guard
            let url = url ?? selectedBudgetURL,
            let pointer = core(for: url)
        else {
            return []
        }

        return ids { output, capacity in
            bw_budget_transaction_ids(pointer, output, capacity)
        }
    }

    func hasCategories(in url: URL? = nil) -> Bool {
        !categoryIDs(in: url).isEmpty
    }

    func categoryTotal(type: BudgetCategoryType, field: CategoryAmountField, in url: URL? = nil) -> UInt64 {
        guard
            let url = url ?? selectedBudgetURL,
            let pointer = core(for: url)
        else {
            return 0
        }

        return bw_budget_category_total(pointer, type.coreType, field.coreField)
    }

    private func savePendingBudget() {
        guard let draft = pendingDraft else {
            return
        }

        do {
            let savedURL = try createBudgetCore(draft)
            pendingDraft = nil
            budgetRows = try loadVaultBudgets()
            externalBudgetURL = nil
            selectedBudgetURL = savedURL
            revision += 1
        } catch {
            presentedError = error.localizedDescription
        }
    }

    private func mutateSelectedBudget(
        _ failure: BWError,
        mutation: (UnsafeMutablePointer<BWBudget>) throws -> Int32
    ) {
        guard
            let selectedBudgetURL,
            let pointer = core(for: selectedBudgetURL)
        else {
            return
        }

        do {
            let result = try accessBudget(selectedBudgetURL) {
                try mutation(pointer)
            }

            guard result == 0 else {
                throw failure
            }

            try accessBudget(selectedBudgetURL) {
                try writeText(jsonString(from: pointer), to: selectedBudgetURL)
            }

            refreshRow(for: selectedBudgetURL)
            revision += 1
        } catch {
            presentedError = error.localizedDescription
        }
    }

    private func loadVaultBudgets() throws -> [BudgetRow] {
        try BWBudgetVault.loadBudgetRows(in: vault.resolveVaultURL())
    }

    private func createBudgetCore(_ draft: BudgetDraft) throws -> URL {
        let vaultURL = try vault.resolveVaultURL()

        return try vault.accessVault {
            let uniqueBudget = vault.uniqueBudgetLocation(for: draft.title, in: vaultURL)
            let pointer = allocateBudget()

            do {
                if let templateURL = draft.templateURL {
                    let result = templateURL.path.withCString {
                        bw_budget_init_from_template(pointer, $0)
                    }

                    guard result == 0 else {
                        throw BWError.budgetCreationFailed
                    }

                    try replaceTitle(uniqueBudget.title, in: pointer)
                } else {
                    try initializeBudget(pointer, title: uniqueBudget.title)
                }

                guard bw_budget_set_id(pointer, Int32(try nextBudgetID(in: vaultURL))) == 0 else {
                    throw BWError.budgetCreationFailed
                }

                try writeText(jsonString(from: pointer), to: uniqueBudget.url)
                setLoadedBudget(pointer, for: uniqueBudget.url)
                return uniqueBudget.url
            } catch {
                freeBudget(pointer)
                throw error
            }
        }
    }

    private func openBudget(at url: URL) throws -> UnsafeMutablePointer<BWBudget> {
        try accessBudget(url) {
            try readBudget(at: url)
        }
    }

    private func readBudget(at url: URL) throws -> UnsafeMutablePointer<BWBudget> {
        let pointer = allocateBudget()

        do {
            try initializeBudget(pointer, json: readText(from: url), url: url)
            return pointer
        } catch {
            freeBudget(pointer)
            throw error
        }
    }

    private func allocateBudget() -> UnsafeMutablePointer<BWBudget> {
        let pointer = UnsafeMutablePointer<BWBudget>.allocate(capacity: 1)
        pointer.initialize(to: BWBudget())
        return pointer
    }

    private nonisolated func freeBudget(_ pointer: UnsafeMutablePointer<BWBudget>) {
        bw_budget_free(pointer)
        pointer.deinitialize(count: 1)
        pointer.deallocate()
    }

    private func setLoadedBudget(_ pointer: UnsafeMutablePointer<BWBudget>, for url: URL) {
        let key = budgetKey(for: url)

        if let existing = loadedBudget {
            freeBudget(existing)
        }

        loadedBudgetURL = key
        loadedBudget = pointer
    }

    private func releaseLoadedBudget() {
        guard let pointer = loadedBudget else {
            return
        }

        freeBudget(pointer)
        loadedBudgetURL = nil
        loadedBudget = nil
    }

    private func core(for url: URL) -> UnsafeMutablePointer<BWBudget>? {
        guard
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
            let pointer = try openBudget(at: selectedBudgetURL)
            setLoadedBudget(pointer, for: selectedBudgetURL)
            revision += 1
        } catch {
            presentedError = error.localizedDescription
        }
    }

    private func row(from pointer: UnsafeMutablePointer<BWBudget>, for url: URL) -> BudgetRow {
        let key = budgetKey(for: url)
        return BudgetRow(
            url: key,
            coreID: Int(pointer.pointee.id),
            title: pointer.pointee.title.swiftString(default: key.deletingPathExtension().lastPathComponent)
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
        guard
            let pointer = core(for: url)
        else {
            return
        }

        let updated = row(from: pointer, for: url)

        if let index = budgetRows.firstIndex(where: { sameFile($0.url, url) }) {
            budgetRows[index] = updated
        } else if externalBudgetURL.map({ sameFile($0, url) }) == true {
            externalBudgetRow = updated
        }
    }

    private func ids(_ fill: (UnsafeMutablePointer<Int32>?, Int) -> Int) -> [Int] {
        let count = fill(nil, 0)

        guard count > 0 else {
            return []
        }

        var output = [Int32](repeating: 0, count: count)
        let written = output.withUnsafeMutableBufferPointer { buffer in
            fill(buffer.baseAddress, buffer.count)
        }

        return output.prefix(written).map(Int.init)
    }

    func category(_ categoryID: Int, in url: URL? = nil) -> BWCategoryView? {
        guard
            let url = url ?? selectedBudgetURL,
            let pointer = core(for: url)
        else {
            return nil
        }

        var view = BWCategoryView()

        guard bw_budget_category_view_by_id(pointer, Int32(categoryID), &view) == 0 else {
            return nil
        }

        return view
    }

    func transaction(
        _ transactionID: Int,
        in url: URL? = nil
    ) -> BWTransactionView? {
        guard
            let url = url ?? selectedBudgetURL,
            let pointer = core(for: url)
        else {
            return nil
        }

        var view = BWTransactionView()

        guard bw_budget_transaction_view_by_id(pointer, Int32(transactionID), &view) == 0 else {
            return nil
        }

        return view
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

    private func readText(from url: URL) throws -> Swift.String {
        do {
            return try Swift.String(contentsOf: url, encoding: .utf8)
        } catch {
            throw BWError.budgetReadFailed(url)
        }
    }

    private func writeText(_ text: Swift.String, to url: URL) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func removeFile(at url: URL) throws {
        do {
            var trashedURL: NSURL?
            try fileManager.trashItem(at: url, resultingItemURL: &trashedURL)
        } catch {
            throw BWError.budgetRemoveFailed(url)
        }
    }

    private func initializeBudget(_ budget: UnsafeMutablePointer<BWBudget>, title: Swift.String) throws {
        guard title.withCString({ bw_budget_init(budget, $0) }) == 0 else {
            throw BWError.budgetCreationFailed
        }
    }

    private func initializeBudget(
        _ budget: UnsafeMutablePointer<BWBudget>,
        json: Swift.String,
        url: URL
    ) throws {
        let result = json.withCString { bw_budget_from_json_str(budget, $0) }

        guard result == 0 else {
            throw BWError.budgetReadFailed(url)
        }
    }

    private func replaceTitle(_ title: Swift.String, in budget: UnsafeMutablePointer<BWBudget>) throws {
        guard title.withCString({ bw_budget_set_title(budget, $0) }) == 0 else {
            throw BWError.budgetCreationFailed
        }
    }

    private func jsonString(from budget: UnsafeMutablePointer<BWBudget>) throws -> Swift.String {
        var jsonArena = BWArena()

        guard bw_arena_init(&jsonArena, Self.jsonArenaCapacity) == 0 else {
            throw BWError.jsonCreationFailed
        }

        defer {
            bw_arena_destroy(&jsonArena)
        }

        let jsonString = bw_budget_to_json_str(budget, &jsonArena)

        guard let jsonData = jsonString.data else {
            throw BWError.jsonCreationFailed
        }

        let json = Swift.String(cString: jsonData)

        guard !json.isEmpty else {
            throw BWError.jsonCreationFailed
        }

        return json
    }

    private func nextBudgetID(in vaultURL: URL) throws -> Int {
        let maxID = try vault.budgetFileURLs(in: vaultURL)
            .compactMap { url -> Int? in
                let pointer = try? readBudget(at: url)
                defer {
                    if let pointer {
                        freeBudget(pointer)
                    }
                }

                return pointer.map { Int($0.pointee.id) }
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
