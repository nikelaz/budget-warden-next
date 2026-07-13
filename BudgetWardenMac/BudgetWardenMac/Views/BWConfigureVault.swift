import SwiftUI
import BudgetWardenAppleCore

struct ConfigureVaultView: View {
    @EnvironmentObject var store: BWStore
    @EnvironmentObject var windowStore: BWWindowStore

    @State private var vaultUrl: URL? = nil
    @State private var isEnablingICloud = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Budget Storage")
                    .font(.title2)
                    .fontWeight(.semibold)
                
                Text("Local files are always available. Enable iCloud to sync additional budgets across your Apple devices.")
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("iCloud")
                    .font(.headline)

                Text(store.isICloudEnabled ? "Enabled" : "Not enabled")
                    .foregroundStyle(.secondary)

                if !store.isICloudEnabled {
                    Button(isEnablingICloud ? "Enabling…" : "Enable iCloud") {
                        isEnablingICloud = true

                        Task {
                            if let error = await store.enableICloud() {
                                windowStore.setError(error)
                            }

                            isEnablingICloud = false
                        }
                    }
                    .disabled(isEnablingICloud)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Text("Local Folder")
                    .font(.headline)

                Text(vaultUrl != nil ? vaultUrl!.path : "Loading Local Folder…")
                    .foregroundStyle(vaultUrl != nil ? .primary : .secondary)
                    .textSelection(.enabled)

                Button("Choose Local Folder") {
                    Task(priority: .userInitiated) {
                        if let error = await store.selectVaultFolder() {
                            windowStore.setError(error)
                        }

                        vaultUrl = await store.vault.currentURL()
                    }
                }
            }

            HStack {
                Spacer()

                Button("Done", role: .cancel) {
                    windowStore.closeVaultConfigDialog() 
                }
                .keyboardShortcut(.cancelAction)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .task {
            vaultUrl = await store.vault.currentURL()
        }
    }
}
