/* 
 * Budget Warden
 * Copyright (c) 2026 Lazarov & Co EOOD
 * Author: Nikola Lazarov
 *
 * Licensed under the Source-Available Educational License. 
 * See the LICENSE file in the project root for full terms.
 */

import SwiftUI
import BWAppleCore

struct BWPreferencesView: View {
    @ObservedObject var store: BWStore
    @Binding var selectedCurrency: BWCurrency
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Preferences")
                .font(.headline)

            Form {
                Picker("Currency", selection: $selectedCurrency) {
                    ForEach(BWCurrency.allCases, id: \.self) { currency in
                        Text(title(for: currency))
                            .tag(currency)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 280)

                if store.googleDrive.isConfigured {
                    Section {
                        googleDriveAccount
                    } header: {
                        Text("Google Drive")
                            .padding(.top, 12)
                    } footer: {
                        Text("Budgets in Google Drive sync between your devices and the people you share them with.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Section {
                    Toggle("Enable MCP server", isOn: Binding(
                        get: { store.mcpSettings?.isEnabled ?? false },
                        set: { store.setMcpServerEnabled($0) }
                    ))
                    Toggle("Allow other devices", isOn: Binding(
                        get: { store.mcpSettings?.allowsNetwork ?? false },
                        set: { store.setMcpServerAllowsNetwork($0) }
                    ))
                    mcpServerAddress
                } header: {
                    Text("MCP Server")
                        .padding(.top, 12)
                } footer: {
                    Text("MCP clients such as AI assistants can read and edit your open and recent budgets through this URL. Keep it private.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack {
                Spacer()

                Button("Done") {
                    onClose()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
    }

    @ViewBuilder
    private var googleDriveAccount: some View {
        let drive = store.googleDrive
        if drive.isSignedIn {
            LabeledContent("Account") {
                HStack {
                    Text(drive.accountEmail ?? "Signed in")
                    Button("Sign Out", role: .destructive) {
                        Task { await drive.signOut() }
                    }
                }
            }
        } else {
            LabeledContent("Account") {
                Button(drive.isSigningIn ? "Signing In…" : "Sign In") {
                    Task { await drive.signIn() }
                }
                .disabled(drive.isSigningIn)
            }
        }
    }

    @ViewBuilder
    private var mcpServerAddress: some View {
        if let error = store.mcpErrorMessage {
            Text(error)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        } else if let url = store.mcpStatus?.url, store.mcpStatus?.running == true {
            LabeledContent("Server URL") {
                HStack {
                    Text(url)
                        .textSelection(.enabled)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .help("Copy URL")
                    Button {
                        store.regenerateMcpServerURL()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("Generate a new URL")
                }
            }
        }
    }

    private func title(for currency: BWCurrency) -> String {
        "\(currency.rawValue) - \(currency.displayName)"
    }
}
