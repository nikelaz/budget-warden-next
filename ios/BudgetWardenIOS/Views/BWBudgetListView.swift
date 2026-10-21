/*
 * Budget Warden
 * Copyright (c) 2026 Lazarov & Co EOOD
 * Author: Nikola Lazarov
 *
 * Licensed under the Source-Available Educational License.
 * See the LICENSE file in the project root for full terms.
 */

import BWAppleCore
import SwiftUI

struct BWBudgetListView: View {
    let store: BWStore
    let createBudget: () -> Void
    let openBudget: () -> Void
    let openRecent: (URL) -> Void

    @State private var sharingGoogleBudget: BWCloudBudget?

    private var hasAnyBudget: Bool {
        !store.localRecentFiles.isEmpty
            || !store.iCloud.budgets.isEmpty
            || !store.googleDrive.budgets.isEmpty
    }

    var body: some View {
        List {
            if !hasAnyBudget {
                emptyState
            }

            if !store.localRecentFiles.isEmpty {
                Section("Recently Opened") {
                    ForEach(store.localRecentFiles, id: \.self) { url in
                        budgetRow(
                            title: url.deletingPathExtension().lastPathComponent,
                            subtitle: BWFileLocationFormatter.displayPath(for: url),
                            systemImage: "doc"
                        ) {
                            openRecent(url)
                        }
                        .accessibilityIdentifier("recentBudget_\(url.lastPathComponent)")
                        .contextMenu {
                            Button("Delete Budget", systemImage: "trash", role: .destructive) {
                                store.deleteRecentBudget(at: url)
                            }
                        }
                    }
                    .onDelete { offsets in
                        let files = store.localRecentFiles
                        for index in offsets where files.indices.contains(index) {
                            store.deleteRecentBudget(at: files[index])
                        }
                    }
                }
            }

            if store.iCloud.isAvailable {
                Section {
                    if store.iCloud.budgets.isEmpty {
                        Text("Create a budget in iCloud Drive to use it on all your devices.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(store.iCloud.budgets) { budget in
                        budgetRow(
                            title: budget.title,
                            subtitle: budget.locationDescription,
                            systemImage: budget.isSharedWithMe ? "person.2" : "icloud"
                        ) {
                            openRecent(budget.url)
                        }
                        .accessibilityIdentifier("iCloudBudget_\(budget.title)")
                        .contextMenu {
                            ShareLink(item: budget.url) {
                                Label("Share", systemImage: "square.and.arrow.up")
                            }
                        }
                        .swipeActions(edge: .leading) {
                            ShareLink(item: budget.url) {
                                Label("Share", systemImage: "square.and.arrow.up")
                            }
                            .tint(.blue)
                        }
                    }
                } header: {
                    Text("iCloud Drive")
                }
            }

            if store.googleDrive.isConfigured {
                googleDriveSection
            }
        }
        .contentMargins(.top, 12, for: .scrollContent)
        .navigationTitle("Budgets")
        .refreshable {
            await store.googleDrive.refresh()
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("New Budget", systemImage: "plus", action: createBudget)
                    Button("Open Budget", systemImage: "folder", action: openBudget)
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Budget")
            }
        }
        .sheet(item: $sharingGoogleBudget) { budget in
            BWGoogleDriveShareView(controller: store.googleDrive, budget: budget) {
                sharingGoogleBudget = nil
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 20) {
            VStack(spacing: 8) {
                Image(systemName: "folder")
                    .font(.system(size: 42, weight: .regular))
                    .foregroundStyle(.secondary)

                Text("No Budgets Yet")
                    .font(.title2.weight(.semibold))

                Text("Create or open a new budget")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Button(action: createBudget) {
                HStack(spacing: 8) {
                    Image(systemName: "plus")
                    Text("Create New Budget")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Button(action: openBudget) {
                Label("Open Budget", systemImage: "folder")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .listRowInsets(EdgeInsets(
            top: 16,
            leading: 20,
            bottom: 16,
            trailing: 20
        ))
    }

    @ViewBuilder
    private var googleDriveSection: some View {
        let drive = store.googleDrive
        Section {
            if let error = drive.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if !drive.isSignedIn {
                Button {
                    Task { await drive.signIn() }
                } label: {
                    Label(
                        drive.isSigningIn ? "Signing In…" : "Connect Google Drive",
                        systemImage: "person.crop.circle.badge.plus"
                    )
                }
                .disabled(drive.isSigningIn)
                .accessibilityIdentifier("connectGoogleDriveButton")
            } else if drive.budgets.isEmpty {
                Text("Create a budget in Google Drive, or add one someone shared with you.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            ForEach(drive.budgets) { budget in
                budgetRow(
                    title: budget.title,
                    subtitle: budget.locationDescription,
                    systemImage: budget.sharedWithMe ? "person.2" : "externaldrive.badge.icloud"
                ) {
                    Task { await store.openGoogleDriveBudget(budget) }
                }
                .accessibilityIdentifier("googleBudget_\(budget.title)")
                .contextMenu {
                    if budget.canShare {
                        Button("Share", systemImage: "person.badge.plus") {
                            sharingGoogleBudget = budget
                        }
                    }
                }
                .swipeActions(edge: .leading) {
                    if budget.canShare {
                        Button("Share", systemImage: "person.badge.plus") {
                            sharingGoogleBudget = budget
                        }
                        .tint(.blue)
                    }
                }
            }
            if drive.isSignedIn, drive.canAddSharedBudgets {
                Button {
                    Task {
                        let added = await drive.addSharedBudgets()
                        if added.count == 1 {
                            await store.openGoogleDriveBudget(added[0])
                        }
                    }
                } label: {
                    Label(drive.isAddingSharedBudgets ? "Choosing…" : "Add Shared Budget…", systemImage: "plus")
                }
                .disabled(drive.isAddingSharedBudgets)
                .accessibilityIdentifier("addSharedGoogleBudgetButton")
            }
        } header: {
            Text("Google Drive")
        } footer: {
            if drive.isSignedIn, let email = drive.accountEmail {
                Text(email)
            } else if !drive.isSignedIn {
                Text("Keep budgets in Google Drive to use them on any device and share them with others.")
            }
        }
    }

    private func budgetRow(
        title: String,
        subtitle: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .foregroundStyle(.secondary)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.primary)

                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
    }
}
