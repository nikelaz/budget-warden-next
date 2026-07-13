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
        VStack(alignment: .leading, spacing: 16) {
            Text("Share “\(budget.title)”")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Enter the email address of the Google Drive user you want to share this budget with. They’ll receive an email invitation from Google Drive.")
                .foregroundStyle(.secondary)

            TextField("Google account email", text: $email)
                .textContentType(.emailAddress)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .disabled(isSharing)
                Button(isSharing ? "Sharing…" : "Share") {
                    isSharing = true
                    Task {
                        if await share(email.trimmingCharacters(in: .whitespacesAndNewlines)) {
                            dismiss()
                        }
                        isSharing = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isSharing || email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
        .interactiveDismissDisabled(isSharing)
    }
}
