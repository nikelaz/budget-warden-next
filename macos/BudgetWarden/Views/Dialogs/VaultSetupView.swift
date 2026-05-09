/* 
 * Budget Warden Core
 * Copyright (c) 2026 Lazarov & Co EOOD
 * Author: Nikola Lazarov
 *
 * Licensed under the Source-Available Educational License. 
 * See the LICENSE file in the project root for full terms.
 *
 */

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct VaultSetupView: View {
    let onChooseICloud: () -> Void
    let onChooseLocal: (URL) -> Void
    let onCancel: () -> Void

    @State private var selectedLocation = VaultLocation.iCloud
    @State private var localParentURL: URL?

    init(
        initialLocalParentURL: URL? = nil,
        onChooseICloud: @escaping () -> Void,
        onChooseLocal: @escaping (URL) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.onChooseICloud = onChooseICloud
        self.onChooseLocal = onChooseLocal
        self.onCancel = onCancel
        self._selectedLocation = State(initialValue: initialLocalParentURL == nil ? .iCloud : .local)
        self._localParentURL = State(initialValue: initialLocalParentURL)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Choose Budget Vault")
                    .font(.title2)
                    .fontWeight(.semibold)
                
                Text("Budget Warden stores every budget in a single vault folder named Budget Warden Budgets.")
                    .foregroundStyle(.secondary)
            }

            Picker("Location", selection: $selectedLocation) {
                Text("iCloud Drive").tag(VaultLocation.iCloud)
                Text("Local Folder").tag(VaultLocation.local)
            }
            .pickerStyle(.radioGroup)

            if selectedLocation == .local {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Location")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text(localParentURL?.path ?? "Choose a folder")
                        .foregroundStyle(localParentURL == nil ? .secondary : .primary)
                        .textSelection(.enabled)

                    Button("Choose...") {
                        chooseLocalFolder()
                    }
                }
            }

            HStack {
                Spacer()

                Button("Cancel", role: .cancel) {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)

                Button("Continue") {
                    continueSetup()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canContinue)
            }
        }
        .padding()
    }

    private var canContinue: Bool {
        selectedLocation == .iCloud || localParentURL != nil
    }

    private func chooseLocalFolder() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.folder]
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.title = "Choose Local Vault Folder"
        panel.message = "Budget Warden will create a Budget Warden Budgets folder inside the selected folder."

        guard panel.runModal() == .OK else {
            return
        }

        localParentURL = panel.url
    }

    private func continueSetup() {
        switch selectedLocation {
        case .iCloud:
            onChooseICloud()
        case .local:
            guard let localParentURL else {
                return
            }

            onChooseLocal(localParentURL)
        }
    }

    private enum VaultLocation {
        case iCloud
        case local
    }
}
