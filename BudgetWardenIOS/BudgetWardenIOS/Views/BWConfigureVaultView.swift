/*
 * Budget Warden
 * Copyright (c) 2026 Lazarov & Co EOOD
 * Author: Nikola Lazarov
 *
 * Licensed under the Source-Available Educational License.
 * See the LICENSE file in the project root for full terms.
 *
 */

import SwiftUI
import UniformTypeIdentifiers

struct BWConfigureVaultView: View {
    let store: BWAppStore

    @Environment(\.dismiss) private var dismiss

    @State private var selectedLocation: BWVaultLocation = .local
    @State private var isFolderImporterPresented = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Location") {
                    Picker("Storage", selection: $selectedLocation) {
                        ForEach(BWVaultLocation.allCases) { location in
                            Text(location.title).tag(location)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: selectedLocation) { _, newLocation in
                        Task {
                            await store.setVaultLocation(newLocation)
                        }
                    }
                }

                Section("Vault Folder") {
                    LabeledContent("Current") {
                        Text(store.vaultURL?.lastPathComponent ?? "Unavailable")
                            .foregroundStyle(store.vaultURL == nil ? .secondary : .primary)
                    }

                    if let vaultURL = store.vaultURL {
                        Text(vaultURL.path)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    Button("Choose Local Folder", systemImage: "folder") {
                        isFolderImporterPresented = true
                    }
                    .disabled(selectedLocation != .local)
                }
            }
            .navigationTitle("Budget Vault")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .task {
                await store.refreshVaultState()
                selectedLocation = store.vaultLocation
            }
            .fileImporter(
                isPresented: $isFolderImporterPresented,
                allowedContentTypes: [.folder],
                allowsMultipleSelection: false
            ) { result in
                Task {
                    switch result {
                        case .failure(let error):
                            store.errorMessage = error.localizedDescription
                        case .success(let urls):
                            guard let url = urls.first else {
                                return
                            }

                            await store.setLocalVaultFolder(url)
                            selectedLocation = store.vaultLocation
                    }
                }
            }
        }
    }
}
