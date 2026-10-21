/*
 * Budget Warden
 * Copyright (c) 2026 Lazarov & Co EOOD
 * Author: Nikola Lazarov
 *
 * Licensed under the Source-Available Educational License.
 * See the LICENSE file in the project root for full terms.
 */

import AppKit
import BWAppleCore
import SwiftUI

private let welcomeWindowWidth: CGFloat = 740
private let welcomeWindowHeight: CGFloat = 370

struct BWWindowWelcome: Scene {
    @EnvironmentObject private var store: BWStore
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @StateObject private var windowStore = BWWindowStore()
    @State private var welcomeWindowReference = BWWindowReference()
    @State private var shouldOpenMainWindowAfterBudgetDialogDismisses = false
    @State private var sharingGoogleBudget: BWCloudBudget?

    var body: some Scene {
        Window("Welcome", id: "window-welcome") {
            HStack(spacing: 0) {
                actionsColumn
                Divider()
                recentsColumn
            }
            .padding(.top, 10)
            .padding(.bottom, 20)
            .frame(
                width: welcomeWindowWidth,
                height: welcomeWindowHeight
            )
            .background(BWWindowReader(reference: welcomeWindowReference))
            .task {
                await store.migrateLegacyBudgetsIfNeeded(windowStore: windowStore)
            }
            .onChange(of: store.mcpShowBudgetRequest) {
                if store.currentBudget != nil {
                    openMainWindow()
                }
            }
            .onOpenURL { url in
                Task {
                    if await store.openBudget(at: url, windowStore: windowStore) {
                        openMainWindow()
                    }
                }
            }
            .alert("Error", isPresented: $windowStore.isErrorState) {
                Button("OK") { windowStore.clearError() }
            } message: {
                Text(windowStore.errorMessage)
            }
            .sheet(
                isPresented: $windowStore.isBudgetDialogOpen,
                onDismiss: openMainWindowAfterBudgetCreation
            ) {
                CreateBudgetView {
                    shouldOpenMainWindowAfterBudgetDialogDismisses = true
                    windowStore.closeBudgetDialog()
                }
                .environmentObject(windowStore)
                .frame(minWidth: 420)
            }
            .sheet(isPresented: $windowStore.isPreferencesDialogOpen) {
                BWPreferencesView(
                    store: store,
                    selectedCurrency: $store.selectedCurrency,
                    onClose: windowStore.closePreferencesDialog
                )
                .frame(minWidth: 420)
            }
            .focusedSceneValue(\.windowStore, windowStore)
        }
        .defaultSize(width: welcomeWindowWidth, height: welcomeWindowHeight)
        .defaultLaunchBehavior(.presented)
        .restorationBehavior(.disabled)
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .commands {
            BWCommands(store: store)
        }
    }

    private var actionsColumn: some View {
        VStack(spacing: 20) {
            VStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 130, height: 130)
                    .accessibilityHidden(true)

                Text("Budget Warden")
                    .font(.largeTitle.weight(.semibold))
            }

            VStack(spacing: 15) {
                Button("Create New Budget", systemImage: "plus") {
                    windowStore.openBudgetDialog()
                }
                Button("Open Budget", systemImage: "folder") {
                    Task {
                        guard let url = await store.openFilePicker(windowStore: windowStore) else {
                            return;
                        }

                        if await store.openBudget(at: url, windowStore: windowStore) {
                            openMainWindow()
                        }
                    }
                }
            }
            Spacer()
        }
        .padding(20)
        .frame(width: 370)
    }

    private var recentsColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Budgets")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .center)
                .multilineTextAlignment(.center)

            if store.localRecentFiles.isEmpty, !store.iCloud.isAvailable, !store.googleDrive.isConfigured {
                ContentUnavailableView(
                    "No Recent Budgets",
                    systemImage: "folder",
                    description: Text("Budgets you open will appear here.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        if !store.localRecentFiles.isEmpty {
                            sectionHeader("Recently Opened")
                            ForEach(store.localRecentFiles, id: \.self) { url in
                                budgetButton(
                                    title: url.deletingPathExtension().lastPathComponent,
                                    subtitle: url.deletingLastPathComponent().path,
                                    systemImage: "doc",
                                    identifier: "Button_\(url)"
                                ) {
                                    await store.openBudget(at: url, windowStore: windowStore)
                                }
                                .contextMenu {
                                    Button("Show in Finder", systemImage: "folder") {
                                        NSWorkspace.shared.activateFileViewerSelecting([url])
                                    }
                                }
                            }
                        }

                        if store.iCloud.isAvailable {
                            sectionHeader("iCloud Drive")
                            if store.iCloud.budgets.isEmpty {
                                placeholder("Create a budget in iCloud Drive to use it on all your devices.")
                            }
                            ForEach(store.iCloud.budgets) { budget in
                                budgetButton(
                                    title: budget.title,
                                    subtitle: budget.locationDescription,
                                    systemImage: budget.isSharedWithMe ? "person.2" : "icloud",
                                    identifier: "iCloudBudget_\(budget.title)"
                                ) {
                                    await store.openBudget(at: budget.url, windowStore: windowStore)
                                }
                                .contextMenu {
                                    ShareLink(item: budget.url) {
                                        Label("Share…", systemImage: "square.and.arrow.up")
                                    }
                                    Button("Show in Finder", systemImage: "folder") {
                                        NSWorkspace.shared.activateFileViewerSelecting([budget.url])
                                    }
                                }
                            }
                        }

                        if store.googleDrive.isConfigured {
                            googleDriveSection
                        }
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 370)
        .sheet(item: $sharingGoogleBudget) { budget in
            BWGoogleDriveShareView(controller: store.googleDrive, budget: budget) {
                sharingGoogleBudget = nil
            }
            .frame(minWidth: 420, minHeight: 420)
        }
    }

    @ViewBuilder
    private var googleDriveSection: some View {
        let drive = store.googleDrive
        HStack {
            sectionHeader("Google Drive")
            Spacer()
            if drive.isSignedIn {
                Button {
                    Task { await drive.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(drive.isRefreshing)
                .help("Refresh")
            }
        }
        if let error = drive.lastError {
            Label(error, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        if !drive.isSignedIn {
            Button {
                Task { await drive.signIn() }
            } label: {
                Label(drive.isSigningIn ? "Signing In…" : "Connect Google Drive", systemImage: "person.crop.circle.badge.plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .buttonStyle(.bordered)
            .disabled(drive.isSigningIn)
            .accessibilityIdentifier("connectGoogleDriveButton")
        } else if drive.budgets.isEmpty {
            placeholder("Create a budget in Google Drive, or add one someone shared with you.")
        }
        ForEach(drive.budgets) { budget in
            budgetButton(
                title: budget.title,
                subtitle: budget.locationDescription,
                systemImage: budget.sharedWithMe ? "person.2" : "externaldrive.badge.icloud",
                identifier: "googleBudget_\(budget.title)"
            ) {
                await store.openGoogleDriveBudget(budget, windowStore: windowStore)
            }
            .contextMenu {
                if budget.canShare {
                    Button("Share…", systemImage: "person.badge.plus") {
                        sharingGoogleBudget = budget
                    }
                }
                if let link = budget.webLink.flatMap(URL.init(string:)) {
                    Button("Open in Google Drive", systemImage: "safari") {
                        NSWorkspace.shared.open(link)
                    }
                }
            }
        }
        if drive.isSignedIn, drive.canAddSharedBudgets {
            Button {
                Task {
                    let added = await drive.addSharedBudgets()
                    if added.count == 1, await store.openGoogleDriveBudget(added[0], windowStore: windowStore) {
                        openMainWindow()
                    }
                }
            } label: {
                Label(drive.isAddingSharedBudgets ? "Choosing…" : "Add Shared Budget…", systemImage: "plus")
            }
            .buttonStyle(.borderless)
            .disabled(drive.isAddingSharedBudgets)
            .help("Choose a budget someone shared with you in Google Drive")
            .accessibilityIdentifier("addSharedGoogleBudgetButton")
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.top, 6)
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func budgetButton(
        title: String,
        subtitle: String,
        systemImage: String,
        identifier: String,
        open: @escaping () async -> Bool
    ) -> some View {
        Button {
            Task {
                if await open() {
                    openMainWindow()
                }
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).fontWeight(.medium)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.roundedRectangle(radius: 8))
        .accessibilityIdentifier(identifier)
    }

    private func openMainWindowAfterBudgetCreation() {
        guard shouldOpenMainWindowAfterBudgetDialogDismisses else { return }
        shouldOpenMainWindowAfterBudgetDialogDismisses = false
        openMainWindow()
    }

    private func openMainWindow() {
        windowStore.closeBudgetDialog()
        openWindow(id: "window-main")
        if let welcomeWindow = welcomeWindowReference.window {
            welcomeWindow.close()
        } else {
            dismissWindow(id: "window-welcome")
        }
    }
}

@MainActor
private final class BWWindowReference {
    weak var window: NSWindow?
}

private struct BWWindowReader: NSViewRepresentable {
    let reference: BWWindowReference

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            reference.window = view.window
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            reference.window = nsView.window
        }
    }
}
