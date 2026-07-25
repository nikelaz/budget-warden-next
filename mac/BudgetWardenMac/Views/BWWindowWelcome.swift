/*
 * Budget Warden
 * Copyright (c) 2026 Lazarov & Co EOOD
 * Author: Nikola Lazarov
 *
 * Licensed under the Source-Available Educational License.
 * See the LICENSE file in the project root for full terms.
 */

import AppKit
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
            Text("Recently Opened")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .center)
                .multilineTextAlignment(.center)

            if store.recentFiles.isEmpty {
                ContentUnavailableView(
                    "No Recent Budgets",
                    systemImage: "folder",
                    description: Text("Budgets you open will appear here.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(store.recentFiles, id: \.self) { url in
                            Button {
                                Task {
                                    if await store.openBudget(at: url, windowStore: windowStore) {
                                        openMainWindow()
                                    }
                                }
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(url.deletingPathExtension().lastPathComponent).fontWeight(.medium)
                                    Text(url.deletingLastPathComponent().path)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                            }
                            .buttonStyle(.bordered)
                            .buttonBorderShape(.roundedRectangle(radius: 8))
                            .accessibilityIdentifier("Button_\(url)")
                            .contextMenu {
                                Button("Show in Finder", systemImage: "folder") {
                                    NSWorkspace.shared.activateFileViewerSelecting([url])
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 370)
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
