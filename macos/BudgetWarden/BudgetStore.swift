import Foundation
import Combine

enum BudgetDialogHost {
    case welcome
    case workspace
}

@MainActor
final class BudgetStore: ObservableObject {
    @Published var budgets: [BudgetDocument] = []
    @Published var externalBudget: BudgetDocument?
    @Published var selectedBudgetURL: URL?
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
    private let repository: BudgetRepository
    private static let selectedCurrencyKey = "SelectedCurrency"

    init(vault: BudgetVault? = nil, repository: BudgetRepository? = nil) {
        let resolvedVault = vault ?? BudgetVault.shared
        self.vault = resolvedVault
        self.repository = repository ?? BudgetRepository(vault: resolvedVault)
        let savedCurrency = UserDefaults.standard.string(forKey: Self.selectedCurrencyKey)
            .flatMap(AppCurrency.init(rawValue:))
        _selectedCurrency = Published(initialValue: savedCurrency ?? .defaultCurrency)
    }

    var availableBudgets: [BudgetDocument] {
        guard let unwrappedExternalBudget = externalBudget else {
            return budgets
        }

        if budgets.contains(where: { sameFile($0.url, unwrappedExternalBudget.url) }) {
            return budgets
        }

        return budgets + [unwrappedExternalBudget]
    }

    var selectedBudget: BudgetDocument? {
        if let selectedBudgetURL {
            if let budget = budgets.first(where: { sameFile($0.url, selectedBudgetURL) }) {
                return budget
            }

            if externalBudget.map({ sameFile($0.url, selectedBudgetURL) }) ?? false {
                return externalBudget
            }
        }

        return budgets.first ?? externalBudget
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

    func selectBudget(_ budget: BudgetDocument) {
        selectedBudgetURL = budget.url
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
            let loadedBudgets = try repository.loadBudgets()
            budgets = loadedBudgets

            if !hasAvailableBudget(at: selectedBudgetURL) {
                selectedBudgetURL = externalBudget?.url ?? loadedBudgets.first?.url
            }
        } catch BudgetError.vaultNotConfigured {
            budgets = []
            selectedBudgetURL = externalBudget?.url
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
            let openedBudget = try repository.openBudget(at: url)

            if let vaultBudget = budgets.first(where: { sameFile($0.url, openedBudget.url) }) {
                externalBudget = nil
                selectedBudgetURL = vaultBudget.url
            } else {
                externalBudget = openedBudget
                selectedBudgetURL = openedBudget.url
            }

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
        mutateSelectedBudget { selectedBudget in
            let draft = CategoryDraft(
                title: title,
                amountPlanned: amountPlanned,
                amountAccumulated: amountAccumulated,
                type: type
            )
            return try repository.addCategory(draft, to: selectedBudget)
        }
    }

    func updateCategory(_ update: CategoryUpdate) {
        mutateSelectedBudget { selectedBudget in
            try repository.updateCategory(update, in: selectedBudget)
        }
    }

    func removeCategory(_ category: BudgetCategory) {
        mutateSelectedBudget { selectedBudget in
            try repository.removeCategory(category, from: selectedBudget)
        }
    }

    func reorderCategories(type: BudgetCategoryType, orderedCategoryIDs: [Int]) {
        mutateSelectedBudget { selectedBudget in
            try repository.reorderCategories(type: type, orderedCategoryIDs: orderedCategoryIDs, in: selectedBudget)
        }
    }

    func addTransaction(_ draft: TransactionDraft) {
        mutateSelectedBudget { selectedBudget in
            try repository.addTransaction(draft, to: selectedBudget)
        }
    }

    func updateTransaction(_ update: TransactionUpdate) {
        mutateSelectedBudget { selectedBudget in
            try repository.updateTransaction(update, in: selectedBudget)
        }
    }

    func removeTransaction(_ transaction: BudgetTransaction) {
        mutateSelectedBudget { selectedBudget in
            try repository.removeTransaction(transaction, from: selectedBudget)
        }
    }

    func removeBudget(_ budget: BudgetDocument) {
        do {
            let wasSelected = selectedBudgetURL.map { sameFile($0, budget.url) } ?? false
            let wasExternal = externalBudget.map { sameFile($0.url, budget.url) } ?? false
            try repository.removeBudget(budget)

            let loadedBudgets = wasExternal ? (try? repository.loadBudgets()) ?? budgets : try repository.loadBudgets()
            budgets = loadedBudgets

            if wasExternal {
                externalBudget = nil
            }

            if wasSelected || !hasBudget(in: loadedBudgets, at: selectedBudgetURL) {
                selectedBudgetURL = externalBudget?.url ?? loadedBudgets.first?.url
            }
        } catch {
            presentedError = error.localizedDescription
        }
    }

    private func savePendingBudget() {
        guard let draft = pendingDraft else {
            return
        }

        do {
            let saved = try repository.createBudget(draft)
            pendingDraft = nil
            isCreatingBudget = false
            budgets = try repository.loadBudgets()
            externalBudget = nil
            selectedBudgetURL = saved.url
            updateStoredBudgetIfPresent(saved)
            clearDialogHostIfIdle()
        } catch {
            presentedError = error.localizedDescription
        }
    }

    private func sameFile(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.standardizedFileURL == rhs.standardizedFileURL
    }

    private func hasAvailableBudget(at url: URL?) -> Bool {
        guard let url else {
            return false
        }

        return availableBudgets.contains { sameFile($0.url, url) }
    }

    private func hasBudget(in budgets: [BudgetDocument], at url: URL?) -> Bool {
        guard let url else {
            return false
        }

        return budgets.contains { sameFile($0.url, url) }
    }

    private func updateBudgetList(afterChanging updated: BudgetDocument) throws {
        if budgets.contains(where: { sameFile($0.url, updated.url) }) {
            budgets = try repository.loadBudgets()
            updateStoredBudgetIfPresent(updated)
        } else {
            externalBudget = updated
        }
    }

    private func mutateSelectedBudget(_ mutation: (BudgetDocument) throws -> BudgetDocument) {
        guard let selectedBudget else {
            return
        }

        do {
            let updated = try mutation(selectedBudget)
            try updateBudgetList(afterChanging: updated)
            selectedBudgetURL = updated.url
        } catch {
            presentedError = error.localizedDescription
        }
    }

    private func updateStoredBudgetIfPresent(_ budget: BudgetDocument) {
        if let index = budgets.firstIndex(where: { sameFile($0.url, budget.url) }) {
            budgets[index] = budget
        } else if externalBudget.map({ sameFile($0.url, budget.url) }) ?? false {
            externalBudget = budget
        }
    }

    private func clearDialogHostIfIdle() {
        if !isCreatingBudget && !isConfiguringVault && !isShowingPreferences {
            dialogHost = nil
        }
    }
}
