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
    @Published var selectedBudgetID: BudgetDocument.ID?
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
        self.repository = repository ?? CoreBudgetRepository(vault: resolvedVault)
        let savedCurrency = UserDefaults.standard.string(forKey: Self.selectedCurrencyKey)
            .flatMap(AppCurrency.init(rawValue:))
        _selectedCurrency = Published(initialValue: savedCurrency ?? .eur)
    }

    var availableBudgets: [BudgetDocument] {
        guard let unwrappedExternalBudget = externalBudget else {
            return budgets
        }

        // check if external budget is a part of the budgets vault
        if !budgets.contains(where: { sameFile($0.url, unwrappedExternalBudget.url) }) {
            return budgets
        }

        return budgets + [unwrappedExternalBudget]
    }

    var selectedBudget: BudgetDocument? {
        if let selectedBudgetID {
            if let budget = budgets.first(where: { $0.id == selectedBudgetID }) {
                return budget
            }

            if externalBudget?.id == selectedBudgetID {
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
        do {
            let activated = try repository.activateBudget(budget)
            updateStoredBudgetIfPresent(activated)
            selectedBudgetID = activated.id
        } catch {
            presentedError = error.localizedDescription
        }
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

            if selectedBudgetID == nil || !availableBudgets.contains(where: { $0.id == selectedBudgetID }) {
                selectedBudgetID = externalBudget?.id ?? loadedBudgets.first?.id
            }

            activateCurrentSelection()
        } catch BudgetVaultError.vaultNotConfigured {
            budgets = []
            selectedBudgetID = externalBudget?.id
            activateCurrentSelection()
        } catch {
            presentedError = error.localizedDescription
        }
    }

    func createBudget(_ draft: BudgetDraft) {
        pendingDraft = draft

        do {
            _ = try vault.resolveVaultURL()
            savePendingBudget()
        } catch BudgetVaultError.vaultNotConfigured {
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
                let activated = try repository.activateBudget(vaultBudget)
                updateStoredBudgetIfPresent(activated)
                selectedBudgetID = activated.id
            } else {
                externalBudget = openedBudget
                selectedBudgetID = openedBudget.id
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
        guard let selectedBudget else {
            return
        }

        do {
            let draft = CategoryDraft(
                title: title,
                amountPlanned: amountPlanned,
                amountAccumulated: amountAccumulated,
                type: type
            )
            let updated = try repository.addCategory(draft, to: selectedBudget)
            try updateBudgetList(afterChanging: updated)

            selectedBudgetID = updated.id
        } catch {
            presentedError = error.localizedDescription
        }
    }

    func updateCategory(_ update: CategoryUpdate) {
        guard let selectedBudget else {
            return
        }

        do {
            let updated = try repository.updateCategory(update, in: selectedBudget)
            try updateBudgetList(afterChanging: updated)

            selectedBudgetID = updated.id
        } catch {
            presentedError = error.localizedDescription
        }
    }

    func removeCategory(_ category: BudgetCategory) {
        guard let selectedBudget else {
            return
        }

        do {
            let updated = try repository.removeCategory(category, from: selectedBudget)
            try updateBudgetList(afterChanging: updated)

            selectedBudgetID = updated.id
        } catch {
            presentedError = error.localizedDescription
        }
    }

    func reorderCategories(type: BudgetCategoryType, orderedCategoryIDs: [Int]) {
        guard let selectedBudget else {
            return
        }

        do {
            let updated = try repository.reorderCategories(type: type, orderedCategoryIDs: orderedCategoryIDs, in: selectedBudget)
            try updateBudgetList(afterChanging: updated)

            selectedBudgetID = updated.id
        } catch {
            presentedError = error.localizedDescription
        }
    }

    func addTransaction(_ draft: TransactionDraft) {
        guard let selectedBudget else {
            return
        }

        do {
            let updated = try repository.addTransaction(draft, to: selectedBudget)
            try updateBudgetList(afterChanging: updated)

            selectedBudgetID = updated.id
        } catch {
            presentedError = error.localizedDescription
        }
    }

    func updateTransaction(_ update: TransactionUpdate) {
        guard let selectedBudget else {
            return
        }

        do {
            let updated = try repository.updateTransaction(update, in: selectedBudget)
            try updateBudgetList(afterChanging: updated)

            selectedBudgetID = updated.id
        } catch {
            presentedError = error.localizedDescription
        }
    }

    func removeTransaction(_ transaction: BudgetTransaction) {
        guard let selectedBudget else {
            return
        }

        do {
            let updated = try repository.removeTransaction(transaction, from: selectedBudget)
            try updateBudgetList(afterChanging: updated)

            selectedBudgetID = updated.id
        } catch {
            presentedError = error.localizedDescription
        }
    }

    func removeBudget(_ budget: BudgetDocument) {
        do {
            let wasSelected = selectedBudgetID == budget.id
            let wasExternal = externalBudget.map { sameFile($0.url, budget.url) } ?? false
            try repository.removeBudget(budget)

            let loadedBudgets = wasExternal ? (try? repository.loadBudgets()) ?? budgets : try repository.loadBudgets()
            budgets = loadedBudgets

            if wasExternal {
                externalBudget = nil
            }

            if wasSelected || !loadedBudgets.contains(where: { $0.id == selectedBudgetID }) {
                selectedBudgetID = externalBudget?.id ?? loadedBudgets.first?.id
            }

            activateCurrentSelection()
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
            selectedBudgetID = saved.id
            updateStoredBudgetIfPresent(saved)
            clearDialogHostIfIdle()
        } catch {
            presentedError = error.localizedDescription
        }
    }

    private func sameFile(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.standardizedFileURL == rhs.standardizedFileURL
    }

    private func updateBudgetList(afterChanging updated: BudgetDocument) throws {
        if budgets.contains(where: { sameFile($0.url, updated.url) }) {
            budgets = try repository.loadBudgets()
            updateStoredBudgetIfPresent(updated)
        } else {
            externalBudget = updated
        }
    }

    private func activateCurrentSelection() {
        guard let selectedBudget else {
            repository.closeActiveBudget()
            return
        }

        do {
            let activated = try repository.activateBudget(selectedBudget)
            updateStoredBudgetIfPresent(activated)
            selectedBudgetID = activated.id
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
