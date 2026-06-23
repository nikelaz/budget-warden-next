import SwiftUI
import AppleCore

struct ConfigureVaultView: View {
    @EnvironmentObject var store: BWStore
    @EnvironmentObject var windowStore: BWWindowStore

    @State private var vaultUrl: URL? = nil
    @State private var selectedLocation: BWVaultLocation = .iCloud

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Choose Budget Vault")
                    .font(.title2)
                    .fontWeight(.semibold)
                
                Text("Budget Warden stores budgets as files in the vault folder.")
                    .foregroundStyle(.secondary)
            }

            Picker("Location", selection: $selectedLocation) {
                ForEach(BWVaultLocation.allCases) { location in
                    Text(location.title).tag(location)
                }
            }
            .pickerStyle(.radioGroup)
            .onChange(of: selectedLocation) { _, newLocation in
                Task {
                    if let error = await store.setVaultLocation(newLocation) {
                        windowStore.setError(error)
                    }

                    vaultUrl = await store.vault.currentURL()
                    selectedLocation = await store.vault.currentLocation()
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Location")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(vaultUrl != nil ? vaultUrl!.path : "Loading Vault URL...")
                    .foregroundStyle(vaultUrl != nil ? .primary : .secondary)
                    .textSelection(.enabled)

                Button("Choose Local Folder") {
                    Task {
                        if let error = await store.selectVaultFolder() {
                            windowStore.setError(error)
                        }

                        vaultUrl = await store.vault.currentURL()
                        selectedLocation = await store.vault.currentLocation()
                    }
                }
                .disabled(selectedLocation != .local)
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
            selectedLocation = await store.vault.currentLocation()
            vaultUrl = await store.vault.currentURL()
        }
    }
}
