/*
 * Budget Warden
 * Copyright (c) 2026 Lazarov & Co EOOD
 * Author: Nikola Lazarov
 *
 * Licensed under the Source-Available Educational License.
 * See the LICENSE file in the project root for full terms.
 */

import BWCore
import SwiftUI

/// Invites people to a Google Drive budget and manages who has access.
public struct BWGoogleDriveShareView: View {
    let controller: BWGoogleDriveController
    let budget: BWCloudBudget
    let onDone: () -> Void

    @State private var email = ""
    @State private var canEdit = true
    @State private var message = ""
    @State private var shares: [BWCloudShare] = []
    @State private var isLoading = true
    @State private var isSending = false
    @State private var errorMessage: String?

    public init(controller: BWGoogleDriveController, budget: BWCloudBudget, onDone: @escaping () -> Void) {
        self.controller = controller
        self.budget = budget
        self.onDone = onDone
    }

    private var canSend: Bool {
        email.contains("@") && !isSending
    }

    public var body: some View {
        NavigationStack {
            Form {
                if budget.canShare {
                    Section {
                        TextField("Email address", text: $email)
                            .autocorrectionDisabled()
                            #if os(iOS)
                            .textContentType(.emailAddress)
                            .keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            #endif
                            .accessibilityIdentifier("shareEmailField")
                        Picker("Permission", selection: $canEdit) {
                            Text("Can edit").tag(true)
                            Text("Can view").tag(false)
                        }
                        TextField("Message (optional)", text: $message)
                        Button {
                            Task { await send() }
                        } label: {
                            if isSending {
                                ProgressView()
                            } else {
                                Label("Send Invite", systemImage: "paperplane")
                            }
                        }
                        .disabled(!canSend)
                        .accessibilityIdentifier("shareSendButton")
                    } header: {
                        Text("Invite")
                    } footer: {
                        Text("They receive an email from Google, and Budget Warden lists the budget for them under budgets shared with them.")
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }

                Section("People With Access") {
                    if isLoading {
                        ProgressView()
                    }
                    ForEach(shares, id: \.id) { share in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(share.displayName ?? share.email ?? title(forKind: share.kind))
                                Text(subtitle(for: share))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if budget.canShare, share.role != .owner {
                                Button(role: .destructive) {
                                    Task { await remove(share) }
                                } label: {
                                    Image(systemName: "person.crop.circle.badge.minus")
                                }
                                .buttonStyle(.borderless)
                                .help("Remove access")
                                .accessibilityLabel("Remove access for \(share.email ?? "this person")")
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Share “\(budget.title)”")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onDone)
                }
            }
        }
        .task { await loadShares() }
    }

    private func send() async {
        isSending = true
        defer { isSending = false }
        do {
            let note = message.trimmingCharacters(in: .whitespacesAndNewlines)
            try await controller.share(budget, with: email, canEdit: canEdit, message: note.isEmpty ? nil : note)
            email = ""
            message = ""
            errorMessage = nil
            await loadShares()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func remove(_ share: BWCloudShare) async {
        do {
            try await controller.removeShare(share, from: budget)
            await loadShares()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadShares() async {
        isLoading = true
        defer { isLoading = false }
        do {
            shares = try await controller.shares(of: budget)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func subtitle(for share: BWCloudShare) -> String {
        let role = switch share.role {
        case .owner: "Owner"
        case .writer: "Can edit"
        case .commenter: "Can comment"
        case .reader: "Can view"
        }
        if share.displayName != nil, let email = share.email {
            return "\(email) · \(role)"
        }
        return role
    }

    private func title(forKind kind: String) -> String {
        switch kind {
        case "anyone": "Anyone with the link"
        case "domain": "Everyone in the organization"
        default: "Unknown"
        }
    }
}
