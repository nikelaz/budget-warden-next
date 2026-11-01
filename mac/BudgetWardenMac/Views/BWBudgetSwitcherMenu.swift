import SwiftUI
import BWAppleCore

/// The toolbar menu for switching budgets, grouped by where each budget is
/// stored: recently opened local files, iCloud Drive, and Google Drive.
struct BWBudgetSwitcherMenu: View {
    @ObservedObject var store: BWStore
    @ObservedObject var windowStore: BWWindowStore

    var body: some View {
        Menu {
            let local = store.localRecentFiles
            if !local.isEmpty {
                Section("Local") {
                    ForEach(local, id: \.self) { url in
                        item(title: url.deletingPathExtension().lastPathComponent, isCurrent: isCurrent(url)) {
                            _ = await store.openBudget(at: url, windowStore: windowStore)
                        }
                    }
                }
            }

            if store.iCloud.isAvailable, !store.iCloud.budgets.isEmpty {
                Section("iCloud") {
                    ForEach(store.iCloud.budgets) { budget in
                        item(title: budget.title, isCurrent: isCurrent(budget.url)) {
                            _ = await store.openBudget(at: budget.url, windowStore: windowStore)
                        }
                    }
                }
            }

            let drive = store.googleDrive
            if drive.isSignedIn, !drive.budgets.isEmpty {
                Section("Google Drive") {
                    ForEach(drive.budgets) { budget in
                        item(title: budget.title, isCurrent: currentDriveID == budget.id) {
                            _ = await store.openGoogleDriveBudget(budget, windowStore: windowStore)
                        }
                    }
                }
            }

            Divider()

            Button {
                windowStore.openBudgetDialog()
            } label: {
                Label("New Budget", systemImage: "plus")
            }
        } label: {
            Text(store.currentBudget?.title ?? "Budget")
        }
        .accessibilityIdentifier("budgetSwitcherMenu")
    }

    private func item(title: String, isCurrent: Bool, open: @escaping () async -> Void) -> some View {
        Button {
            Task { await open() }
        } label: {
            if isCurrent {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }

    private var currentURL: URL? {
        store.currentBudget?.url.map { URL(fileURLWithPath: $0).standardizedFileURL }
    }

    private func isCurrent(_ url: URL) -> Bool {
        currentURL == url.standardizedFileURL
    }

    private var currentDriveID: String? {
        currentURL.flatMap { store.googleDrive.budgetID(for: $0) }
    }
}
