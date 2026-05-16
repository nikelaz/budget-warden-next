import SwiftUI

struct ConfigureVaultView: View {
    @EnvironmentObject var store: BWStore
    @EnvironmentObject var windowStore: BWWindowStore

    @State private var vaultUrl: URL? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Choose Budget Vault")
                    .font(.title2)
                    .fontWeight(.semibold)
                
                Text("Budget Warden stores budgets as files in the vault folder.")
                    .foregroundStyle(.secondary)
            }

            /*
            @TODO(Niki): iCloud vault
            Picker("Location", selection: $selectedLocation) {
                Text("iCloud Drive").tag(VaultLocation.iCloud)
                Text("Local Folder").tag(VaultLocation.local)
            }
            .pickerStyle(.radioGroup)
            */

            VStack(alignment: .leading, spacing: 10) {
                Text("Location")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(vaultUrl != nil ? vaultUrl!.path : "Loading Vault URL...")
                    .foregroundStyle(vaultUrl != nil ? .primary : .secondary)
                    .textSelection(.enabled)

                Button("Choose Folder") {
                    Task {
                        await store.selectVaultFolder()
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
