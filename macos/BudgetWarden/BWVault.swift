import Foundation
import AppKit

private let VAULT_PATH_KEY = "BW_VAULT_PATH"

struct BWVault {
    private let fileManager = FileManager.default
    var url: URL?

    init() {
        if let path = UserDefaults.standard.string(forKey: VAULT_PATH_KEY) {
            self.url = URL(fileURLWithPath: path)
        } else {
            self.url = nil
        }
    }

    mutating func selectVaultFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false

        if panel.runModal() != .OK {
            return nil
        }

        if let selectedUrl = panel.url {
            UserDefaults.standard.set(selectedUrl.path, forKey: VAULT_PATH_KEY)
            self.url = selectedUrl
            return url
        }

        return nil
    }

    func readBudgetsFromVault() -> Result<[BWBudget], BWError> {
        guard let url = url else {
            return .failure(.vaultNotSet)
        }

        let budgets = readBudgetsFromDirectory(url: url)

        return .success(budgets)
    }
 
    func readBudgetsFromDirectory(url: URL) -> [BWBudget] {
        guard let files = try? fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }

        let budgetFiles = files.filter { $0.pathExtension == "budget" }

        var budgets: [BWBudget] = []

        for file in budgetFiles {
            guard let json = try? String(contentsOf: file, encoding: .utf8) else {
                continue
            }

            let result = BWCodec.decodeBudget(json: json)

            switch result {
            case .success(let budget):
                budgets.append(budget)

            case .failure:
                continue
            }
        }

        return budgets
    }
}
