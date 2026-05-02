import Foundation
import Combine

@MainActor
final class BudgetStore: ObservableObject {
    @Published var budgets: [BudgetDocument] = []
    @Published var externalBudget: BudgetDocument?
    @Published var selectedBudgetID: BudgetDocument.ID?
    @Published var isCreatingBudget = false
    @Published var isConfiguringVault = false
    @Published var presentedError: Swift.String?

    private var pendingDraft: BudgetDraft?
    private let vault: BudgetVault

    init(vault: BudgetVault? = nil) {
        self.vault = vault ?? BudgetVault.shared
    }

    var availableBudgets: [BudgetDocument] {
        guard
            let externalBudget,
            !budgets.contains(where: { sameFile($0.url, externalBudget.url) })
        else {
            return budgets
        }

        return budgets + [externalBudget]
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

    func showCreateBudget() {
        presentedError = nil
        isCreatingBudget = true
    }

    func showVaultSetup() {
        presentedError = nil
        isConfiguringVault = true
    }

    func selectBudget(_ budget: BudgetDocument) {
        selectedBudgetID = budget.id
    }

    func cancelCreateBudget() {
        isCreatingBudget = false
    }

    func cancelVaultSetup() {
        pendingDraft = nil
        isConfiguringVault = false
    }

    func loadBudgets() {
        do {
            let loadedBudgets = try vault.loadBudgets()
            budgets = loadedBudgets

            if selectedBudgetID == nil || !loadedBudgets.contains(where: { $0.id == selectedBudgetID }) {
                selectedBudgetID = externalBudget?.id ?? loadedBudgets.first?.id
            }
        } catch BudgetVaultError.vaultNotConfigured {
            budgets = []
            selectedBudgetID = externalBudget?.id
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

        do {
            try vault.configureVault(parentURL: parentURL)
            isConfiguringVault = false

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

        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let openedBudget = try BudgetCodec.readBudget(from: url)

            if let vaultBudget = budgets.first(where: { sameFile($0.url, openedBudget.url) }) {
                externalBudget = nil
                selectedBudgetID = vaultBudget.id
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

    func addCategory(title: Swift.String, amountPlanned: UInt64, type: BudgetCategoryType) {
        guard let selectedBudget else {
            return
        }

        do {
            let draft = CategoryDraft(title: title, amountPlanned: amountPlanned, type: type)
            let updated: BudgetDocument

            if budgets.contains(where: { sameFile($0.url, selectedBudget.url) }) {
                updated = try vault.addCategory(draft, to: selectedBudget)
                budgets = try vault.loadBudgets()
            } else {
                let didAccess = selectedBudget.url.startAccessingSecurityScopedResource()
                defer {
                    if didAccess {
                        selectedBudget.url.stopAccessingSecurityScopedResource()
                    }
                }

                updated = try BudgetCodec.addCategory(draft, to: selectedBudget.url)
                externalBudget = updated
            }

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
            let updated: BudgetDocument

            if budgets.contains(where: { sameFile($0.url, selectedBudget.url) }) {
                updated = try vault.addTransaction(draft, to: selectedBudget)
                budgets = try vault.loadBudgets()
            } else {
                let didAccess = selectedBudget.url.startAccessingSecurityScopedResource()
                defer {
                    if didAccess {
                        selectedBudget.url.stopAccessingSecurityScopedResource()
                    }
                }

                updated = try BudgetCodec.addTransaction(draft, to: selectedBudget.url)
                externalBudget = updated
            }

            selectedBudgetID = updated.id
        } catch {
            presentedError = error.localizedDescription
        }
    }

    private func savePendingBudget() {
        guard let draft = pendingDraft else {
            return
        }

        do {
            let saved = try vault.saveBudget(draft)
            pendingDraft = nil
            isCreatingBudget = false
            budgets = try vault.loadBudgets()
            externalBudget = nil
            selectedBudgetID = saved.id
        } catch {
            presentedError = error.localizedDescription
        }
    }

    private func sameFile(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.standardizedFileURL == rhs.standardizedFileURL
    }
}
