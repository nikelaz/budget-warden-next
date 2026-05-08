import Foundation
import Combine

enum BudgetDialogHost {
    case welcome
    case workspace
}

@MainActor
final class BudgetStore: ObservableObject {
    @Published private(set) var budgetRows: [BudgetRow] = []
    @Published var externalBudgetURL: URL?
    @Published var selectedBudgetURL: URL?
    @Published private(set) var revision = 0
    @Published var isCreatingBudget = false
    @Published var isConfiguringVault = false
    @Published var isShowingPreferences = false
    @Published var dialogHost: BudgetDialogHost?
    @Published var presentedError: Swift.String?
    @Published var selectedCurrency: AppCurrency {
        didSet {
            UserDefaults.standard.set(selectedCurrency.rawValue, forKey: Self.selectedCurrencyKey)
        }
    }

    private var pendingDraft: BudgetDraft?
    private let vault: BudgetVault
    private let fileManager = FileManager.default
    private var cores: [URL: UnsafeMutablePointer<BWBudget>] = [:]
    private static let selectedCurrencyKey = "SelectedCurrency"
    private static let jsonArenaCapacity = 1024 * 1024

    init(vault: BudgetVault? = nil) {
        let resolvedVault = vault ?? BudgetVault.shared
        self.vault = resolvedVault
        let savedCurrency = UserDefaults.standard.string(forKey: Self.selectedCurrencyKey)
            .flatMap(AppCurrency.init(rawValue:))
        _selectedCurrency = Published(initialValue: savedCurrency ?? .defaultCurrency)
    }

    deinit {
        for pointer in cores.values {
            freeBudget(pointer)
        }
    }

    var budgets: [BudgetRow] {
        budgetRows
    }

    var availableBudgetRows: [BudgetRow] {
        guard
            let externalBudgetURL,
            let externalRow = row(for: externalBudgetURL)
        else {
            return budgetRows
        }

        if budgetRows.contains(where: { sameFile($0.url, externalBudgetURL) }) {
            return budgetRows
        }

        return budgetRows + [externalRow]
    }

    var selectedBudgetRow: BudgetRow? {
        if let selectedBudgetURL, let row = row(for: selectedBudgetURL) {
            return row
        }

        return budgetRows.first ?? externalBudgetURL.flatMap(row(for:))
    }

    var configuredLocalVaultParentURL: URL? {
        vault.configuredLocalParentURL()
    }

    func showCreateBudget(from host: BudgetDialogHost) {
        presentedError = nil
        dialogHost = host
        isCreatingBudget = true
    }

    func showVaultSetup(from host: BudgetDialogHost) {
        presentedError = nil
        dialogHost = host
        isConfiguringVault = true
    }

    func showPreferences(from host: BudgetDialogHost) {
        dialogHost = host
        isShowingPreferences = true
    }

    func selectBudget(_ budget: BudgetRow) {
        selectedBudgetURL = budget.url
    }

    func selectBudget(url: URL) {
        selectedBudgetURL = url
    }

    func cancelCreateBudget() {
        isCreatingBudget = false
        clearDialogHostIfIdle()
    }

    func cancelVaultSetup() {
        pendingDraft = nil
        isConfiguringVault = false
        clearDialogHostIfIdle()
    }

    func closePreferences() {
        isShowingPreferences = false
        clearDialogHostIfIdle()
    }

    func loadBudgets() {
        do {
            let loadedRows = try loadVaultBudgets()
            budgetRows = loadedRows

            if !hasAvailableBudget(at: selectedBudgetURL) {
                selectedBudgetURL = externalBudgetURL ?? loadedRows.first?.url
            }
        } catch BudgetError.vaultNotConfigured {
            releaseVaultBudgets()
            budgetRows = []
            selectedBudgetURL = externalBudgetURL
        } catch {
            presentedError = error.localizedDescription
        }
    }

    func createBudget(_ draft: BudgetDraft) {
        pendingDraft = draft

        do {
            _ = try vault.resolveVaultURL()
            savePendingBudget()
        } catch BudgetError.vaultNotConfigured {
            isCreatingBudget = false

            DispatchQueue.main.async {
                self.isConfiguringVault = true
            }
        } catch {
            presentedError = error.localizedDescription
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
            isConfiguringVault = false

            if pendingDraft == nil {
                clearDialogHostIfIdle()
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
                selectedBudgetURL = vaultBudget.url
                return true
            }

            let pointer = try openBudget(at: url)
            replaceCore(pointer, for: key)
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
        mutateSelectedBudget(BudgetError.categoryCreationFailed) { budget in
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
        mutateSelectedBudget(BudgetError.categorySaveFailed) { budget in
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
        mutateSelectedBudget(BudgetError.categoryNotFound) { budget in
            bw_budget_remove_category(budget, Int32(categoryID))
        }
    }

    func reorderCategories(type: BudgetCategoryType, orderedCategoryIDs: [Int]) {
        mutateSelectedBudget(BudgetError.categorySaveFailed) { budget in
            let coreCategoryIDs = orderedCategoryIDs.map(Int32.init)
            return coreCategoryIDs.withUnsafeBufferPointer { buffer in
                bw_budget_reorder_categories(budget, type.coreType, buffer.baseAddress, buffer.count)
            }
        }
    }

    func addTransaction(_ draft: TransactionDraft) {
        mutateSelectedBudget(BudgetError.transactionCreationFailed) { budget in
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
        mutateSelectedBudget(BudgetError.transactionSaveFailed) { budget in
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
        mutateSelectedBudget(BudgetError.transactionNotFound) { budget in
            bw_budget_remove_transaction(budget, Int32(transactionID))
        }
    }

    func removeBudget(_ budget: BudgetRow) {
        removeBudget(url: budget.url)
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
                releaseCore(for: key)
                externalBudgetURL = nil
            }

            budgetRows = try loadVaultBudgets()

            if wasSelected || !hasAvailableBudget(at: selectedBudgetURL) {
                selectedBudgetURL = externalBudgetURL ?? budgetRows.first?.url
            }

            revision += 1
        } catch {
            presentedError = error.localizedDescription
        }
    }

    func categoryIDs(for type: BudgetCategoryType, in url: URL? = nil) -> [Int] {
        guard
            let url = resolvedBudgetURL(url),
            let items = core(for: url)?.pointee.categories.items
        else {
            return []
        }

        let categories: [(id: Int, ordinal: Int)] = (0..<coreCategoryCount(for: url)).compactMap { index in
            let category = items[index]
            guard category.category_type == type.coreType else {
                return nil
            }

            return (id: Int(category.id), ordinal: Int(category.ordinal))
        }

        return categories.sorted {
            if $0.ordinal != $1.ordinal {
                return $0.ordinal < $1.ordinal
            }

            return $0.id < $1.id
        }
        .map(\.id)
    }

    func categoryIDs(in url: URL? = nil) -> [Int] {
        BudgetCategoryType.allCases.flatMap { categoryIDs(for: $0, in: url) }
    }

    func transactionIDs(in url: URL? = nil) -> [Int] {
        guard
            let url = resolvedBudgetURL(url),
            let items = core(for: url)?.pointee.categories.items
        else {
            return []
        }

        let transactionIDs = (0..<coreCategoryCount(for: url)).flatMap { categoryIndex -> [(id: Int, date: BWDate)] in
            let transactions = items[categoryIndex].transactions

            guard let transactionItems = transactions.items else {
                return []
            }

            return (0..<transactions.length).map { transactionIndex in
                let transaction = transactionItems[transactionIndex]
                return (id: Int(transaction.id), date: transaction.date)
            }
        }

        return transactionIDs.sorted {
            if $0.date.year != $1.date.year {
                return $0.date.year > $1.date.year
            }

            if $0.date.month != $1.date.month {
                return $0.date.month > $1.date.month
            }

            if $0.date.day != $1.date.day {
                return $0.date.day > $1.date.day
            }

            return $0.id > $1.id
        }
        .map(\.id)
    }

    func hasCategories(in url: URL? = nil) -> Bool {
        !categoryIDs(in: url).isEmpty
    }

    func categoryTitle(_ categoryID: Int, in url: URL? = nil) -> Swift.String {
        category(categoryID, in: url)?.title.swiftString() ?? ""
    }

    func categoryType(_ categoryID: Int, in url: URL? = nil) -> BudgetCategoryType? {
        category(categoryID, in: url).flatMap { BudgetCategoryType(coreType: $0.category_type) }
    }

    func categoryOrdinal(_ categoryID: Int, in url: URL? = nil) -> Int {
        category(categoryID, in: url).map { Int($0.ordinal) } ?? 0
    }

    func categoryAmount(_ categoryID: Int, field: CategoryAmountField, in url: URL? = nil) -> UInt64 {
        guard let category = category(categoryID, in: url) else {
            return 0
        }

        switch field {
        case .planned:
            return category.amount_planned
        case .actual:
            return category.amount_actual
        case .accumulated:
            return category.amount_accumulated
        }
    }

    func categoryTotal(type: BudgetCategoryType, field: CategoryAmountField, in url: URL? = nil) -> UInt64 {
        categoryIDs(for: type, in: url).reduce(0) { total, categoryID in
            total + categoryAmount(categoryID, field: field, in: url)
        }
    }

    func transactionTitle(_ transactionID: Int, in url: URL? = nil) -> Swift.String {
        transaction(transactionID, in: url)?.transaction.title.swiftString() ?? ""
    }

    func transactionDescription(_ transactionID: Int, in url: URL? = nil) -> Swift.String {
        transaction(transactionID, in: url)?.transaction.description.swiftString() ?? ""
    }

    func transactionDate(_ transactionID: Int, in url: URL? = nil) -> BWDate {
        transaction(transactionID, in: url)?.transaction.date ?? BWDate()
    }

    func transactionAmount(_ transactionID: Int, in url: URL? = nil) -> UInt64 {
        transaction(transactionID, in: url)?.transaction.amount ?? 0
    }

    func transactionCategoryID(_ transactionID: Int, in url: URL? = nil) -> Int {
        transaction(transactionID, in: url).map { Int($0.category.id) } ?? 0
    }

    func transactionCategoryTitle(_ transactionID: Int, in url: URL? = nil) -> Swift.String {
        transaction(transactionID, in: url)?.category.title.swiftString() ?? ""
    }

    func transactionCategoryType(_ transactionID: Int, in url: URL? = nil) -> BudgetCategoryType? {
        transaction(transactionID, in: url).flatMap { BudgetCategoryType(coreType: $0.category.category_type) }
    }

    func transactionFormattedDate(_ transactionID: Int, in url: URL? = nil) -> Swift.String {
        transactionDate(transactionID, in: url).formattedDate
    }

    private func savePendingBudget() {
        guard let draft = pendingDraft else {
            return
        }

        do {
            let savedURL = try createBudgetCore(draft)
            pendingDraft = nil
            isCreatingBudget = false
            budgetRows = try loadVaultBudgets()
            externalBudgetURL = nil
            selectedBudgetURL = savedURL
            clearDialogHostIfIdle()
            revision += 1
        } catch {
            presentedError = error.localizedDescription
        }
    }

    private func mutateSelectedBudget(
        _ failure: BudgetError,
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
        let vaultURL = try vault.resolveVaultURL()

        return try vault.accessVault {
            let urls = try vault.budgetFileURLs(in: vaultURL)
            let urlKeys = Set(urls.map(budgetKey(for:)))

            for row in budgetRows where !urlKeys.contains(budgetKey(for: row.url)) {
                releaseCore(for: row.url)
            }

            let rows = try urls.compactMap { url -> BudgetRow? in
                let key = budgetKey(for: url)
                let pointer = try readBudget(at: key)
                replaceCore(pointer, for: key)
                return row(for: key)
            }

            return rows.sorted(by: Self.sortByFileName)
        }
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
                        throw BudgetError.budgetCreationFailed
                    }

                    try replaceTitle(uniqueBudget.title, in: pointer)
                } else {
                    try initializeBudget(pointer, title: uniqueBudget.title)
                }

                pointer.pointee.id = Int32(try nextBudgetID(in: vaultURL))
                try writeText(jsonString(from: pointer), to: uniqueBudget.url)
                replaceCore(pointer, for: uniqueBudget.url)
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

    private func replaceCore(_ pointer: UnsafeMutablePointer<BWBudget>, for url: URL) {
        let key = budgetKey(for: url)

        if let existing = cores[key] {
            freeBudget(existing)
        }

        cores[key] = pointer
    }

    private func releaseCore(for url: URL) {
        let key = budgetKey(for: url)

        guard let pointer = cores.removeValue(forKey: key) else {
            return
        }

        freeBudget(pointer)
    }

    private func releaseVaultBudgets() {
        for row in budgetRows {
            releaseCore(for: row.url)
        }
    }

    private func core(for url: URL) -> UnsafeMutablePointer<BWBudget>? {
        cores[budgetKey(for: url)]
    }

    private func row(for url: URL) -> BudgetRow? {
        guard let pointer = core(for: url) else {
            return nil
        }

        let key = budgetKey(for: url)
        return BudgetRow(
            url: key,
            coreID: Int(pointer.pointee.id),
            title: pointer.pointee.title.swiftString(default: key.deletingPathExtension().lastPathComponent)
        )
    }

    private func refreshRow(for url: URL) {
        guard let updated = row(for: url) else {
            return
        }

        if let index = budgetRows.firstIndex(where: { sameFile($0.url, url) }) {
            budgetRows[index] = updated
        }
    }

    private func resolvedBudgetURL(_ url: URL?) -> URL? {
        url ?? selectedBudgetURL
    }

    private func coreCategoryCount(for url: URL) -> Int {
        core(for: url).map { Int($0.pointee.categories.length) } ?? 0
    }

    private func category(_ categoryID: Int, in url: URL? = nil) -> BWCategory? {
        guard
            let url = resolvedBudgetURL(url),
            let pointer = core(for: url),
            let items = pointer.pointee.categories.items
        else {
            return nil
        }

        for index in 0..<pointer.pointee.categories.length {
            let category = items[index]

            if Int(category.id) == categoryID {
                return category
            }
        }

        return nil
    }

    private func transaction(
        _ transactionID: Int,
        in url: URL? = nil
    ) -> (transaction: BWTransaction, category: BWCategory)? {
        guard
            let url = resolvedBudgetURL(url),
            let pointer = core(for: url),
            let categories = pointer.pointee.categories.items
        else {
            return nil
        }

        for categoryIndex in 0..<pointer.pointee.categories.length {
            let category = categories[categoryIndex]

            guard let transactions = category.transactions.items else {
                continue
            }

            for transactionIndex in 0..<category.transactions.length {
                let transaction = transactions[transactionIndex]

                if Int(transaction.id) == transactionID {
                    return (transaction, category)
                }
            }
        }

        return nil
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
            throw BudgetError.budgetReadFailed(url)
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
            throw BudgetError.budgetRemoveFailed(url)
        }
    }

    private func initializeBudget(_ budget: UnsafeMutablePointer<BWBudget>, title: Swift.String) throws {
        guard title.withCString({ bw_budget_init(budget, $0) }) == 0 else {
            throw BudgetError.budgetCreationFailed
        }
    }

    private func initializeBudget(
        _ budget: UnsafeMutablePointer<BWBudget>,
        json: Swift.String,
        url: URL
    ) throws {
        let result = json.withCString { bw_budget_from_json_str(budget, $0) }

        guard result == 0 else {
            throw BudgetError.budgetReadFailed(url)
        }
    }

    private func replaceTitle(_ title: Swift.String, in budget: UnsafeMutablePointer<BWBudget>) throws {
        var newTitle = BWString()

        guard bw_string_init(&newTitle, &budget.pointee.arena) == 0 else {
            throw BudgetError.budgetCreationFailed
        }

        guard title.withCString({ bw_string_append(&newTitle, $0) }) == 0 else {
            throw BudgetError.budgetCreationFailed
        }

        budget.pointee.title = newTitle
    }

    private func jsonString(from budget: UnsafeMutablePointer<BWBudget>) throws -> Swift.String {
        var jsonArena = BWArena()

        guard bw_arena_init(&jsonArena, Self.jsonArenaCapacity) == 0 else {
            throw BudgetError.jsonCreationFailed
        }

        defer {
            bw_arena_destroy(&jsonArena)
        }

        let jsonString = bw_budget_to_json_str(budget, &jsonArena)

        guard let jsonData = jsonString.data else {
            throw BudgetError.jsonCreationFailed
        }

        let json = Swift.String(cString: jsonData)

        guard !json.isEmpty else {
            throw BudgetError.jsonCreationFailed
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

        return try BudgetVault.accessSecurityScopedResource(url, operation: operation)
    }

    nonisolated private static func sortByFileName(_ lhs: BudgetRow, _ rhs: BudgetRow) -> Bool {
        lhs.url.lastPathComponent.localizedStandardCompare(rhs.url.lastPathComponent) == .orderedAscending
    }

    private func clearDialogHostIfIdle() {
        if !isCreatingBudget && !isConfiguringVault && !isShowingPreferences {
            dialogHost = nil
        }
    }
}
