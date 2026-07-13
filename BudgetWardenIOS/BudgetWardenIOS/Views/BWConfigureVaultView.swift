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
import BudgetWardenAppleCore

struct BWConfigureVaultView: View {
    let store: BWStore

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                BWVaultSettingsSections(store: store)
            }
            .navigationTitle("Budget Storage")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

struct BWVaultSettingsSections: View {
    let store: BWStore

    @State private var isFolderImporterPresented = false
    @State private var isEnablingICloud = false

    var body: some View {
        Group {
            Section("iCloud") {
                LabeledContent("Sync", value: store.isICloudEnabled ? "Enabled" : "Not Enabled")

                if !store.isICloudEnabled {
                    Button(isEnablingICloud ? "Enabling…" : "Enable iCloud", systemImage: "icloud") {
                        isEnablingICloud = true

                        Task {
                            _ = await store.enableICloud()
                            isEnablingICloud = false
                        }
                    }
                    .disabled(isEnablingICloud)
                }
            }

            Section("Local Folder") {
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
            }
        }
        .task {
            await store.refreshVaultState()
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
                }
            }
        }
    }
}
