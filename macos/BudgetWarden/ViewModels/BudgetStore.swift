import Foundation
import Combine

@MainActor
final class BudgetStore: ObservableObject {
    @Published var budgets: [BudgetDocument] = []
    @Published var selectedBudgetID: BudgetDocument.ID?
    @Published var isCreatingBudget = false
    @Published var isConfiguringVault = false
    @Published var presentedError: Swift.String?

    private var pendingDraft: BudgetDraft?
    private let vault: BudgetVault

    init(vault: BudgetVault? = nil) {
        self.vault = vault ?? BudgetVault.shared
    }

    var selectedBudget: BudgetDocument? {
        budgets.first { $0.id == selectedBudgetID } ?? budgets.first
    }

    func showCreateBudget() {
        presentedError = nil
        isCreatingBudget = true
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
                selectedBudgetID = loadedBudgets.first?.id
            }
        } catch BudgetVaultError.vaultNotConfigured {
            budgets = []
            selectedBudgetID = nil
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
            savePendingBudget()
        } catch {
            presentedError = error.localizedDescription
        }
    }

    func addCategory(title: Swift.String, type: BudgetCategoryType) {
        guard let selectedBudget else {
            return
        }

        do {
            let updated = try vault.addCategory(
                CategoryDraft(title: title, type: type),
                to: selectedBudget
            )

            budgets = try vault.loadBudgets()
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
            selectedBudgetID = saved.id
        } catch {
            presentedError = error.localizedDescription
        }
    }
}
