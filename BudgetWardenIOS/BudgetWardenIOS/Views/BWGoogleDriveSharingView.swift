/*
 * Budget Warden
 * Copyright (c) 2026 Lazarov & Co EOOD
 * Author: Nikola Lazarov
 *
 * Licensed under the Source-Available Educational License.
 * See the LICENSE file in the project root for full terms.
 */

import BudgetWardenAppleCore
import SwiftUI

struct BWGoogleDriveSharingView: View {
    let budget: BWBudget
    let share: (String) async -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var isSharing = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Enter the email address of the Google Drive user you want to share this budget with. They’ll receive an email invitation from Google Drive.")
                        .foregroundStyle(.secondary)

                    TextField("Google account email", text: $email)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            }
            .navigationTitle("Share “\(budget.title)”")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSharing)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSharing ? "Sharing…" : "Share") {
                        isSharing = true
                        Task {
                            if await share(email.trimmingCharacters(in: .whitespacesAndNewlines)) {
                                dismiss()
                            }
                            isSharing = false
                        }
                    }
                    .disabled(isSharing || email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
        .interactiveDismissDisabled(isSharing)
    }
}
