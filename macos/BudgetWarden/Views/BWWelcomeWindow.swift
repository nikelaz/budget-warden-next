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

private let WINDOW_WIDTH: CGFloat = 760
private let WINDOW_HEIGHT: CGFloat = 420

struct BWWelcomeWindow: Scene { 
    @EnvironmentObject var store: BWStore

    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    @StateObject private var windowStore = BWWindowStore()

    @State private var isDeleteBudgetDialogPresented: Bool = false
    @State private var budgetPendingRemoval: BWBudget? = nil

    var body: some Scene {
        Window("Budget Warden", id: "window-welcome") {
            HStack(spacing: 0) {
                leftColumn
                rightColumn
            }
            .frame(
                minWidth: WINDOW_WIDTH,
                idealWidth: WINDOW_WIDTH,
                maxWidth: WINDOW_WIDTH,
                minHeight: WINDOW_HEIGHT,
                idealHeight: WINDOW_HEIGHT,
                maxHeight: WINDOW_HEIGHT
            )
            .containerBackground(.thinMaterial, for: .window)
            .task {
                await store.loadBudgetsFromVault()
            }
            .alert("Error", isPresented: $windowStore.isErrorState) {
                Button("OK") {
                    windowStore.clearError()
                }
            } message: {
                Text(windowStore.errorMessage)
            }
            .alert(
                "Remove Budget?",
                isPresented: $isDeleteBudgetDialogPresented,
                presenting: budgetPendingRemoval
            ) { budget in
                Button("Move to Trash", role: .destructive) {
                    guard let budgetUrl = budget.url else {
                        windowStore.setError(.budgetRemove())
                        return
                    }

                    Task {
                        await store.removeBudget(
                            url: budgetUrl,
                            windowStore: windowStore
                        )
                        budgetPendingRemoval = nil
                    }
                }

                Button("Cancel", role: .cancel) {
                    budgetPendingRemoval = nil
                }
            } message: { budget in
                if budget.url != nil {
                    Text("Move \(budget.url!.lastPathComponent) to Trash?")
                }
                else {
                    Text("Move budget to trash?")
                }
            }
            .sheet(isPresented: $windowStore.isBudgetDialogOpen) {
                CreateBudgetView()
                .environmentObject(windowStore)
                .frame(minWidth: 420)
            }
        }
        .defaultSize(width: WINDOW_WIDTH, height: WINDOW_HEIGHT)
        .defaultLaunchBehavior(.presented)
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
    }

    var leftColumn: some View {
        VStack(alignment: .center, spacing: 20) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 130, height: 130)
                .accessibilityHidden(true)
            
            Text("Budget Warden")
                .font(.largeTitle)
                .fontWeight(.semibold)
            
            VStack(alignment: .center, spacing: 10) {
                Button("Create New Budget", systemImage: "plus") {
                    windowStore.openBudgetDialog()
                }
                
                Button("Open Budget", systemImage: "folder") {
                    if store.openBudget(windowStore: windowStore) {
                        openWindow(id: "window-main")
                        dismissWindow(id: "window-welcome")
                    }
                }
                
                Button("Select Vault Folder", systemImage: "externaldrive") {
                    Task {
                        await store.selectVaultFolder()
                    }
                }
            }
            
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity)
    }

    var noBudgetsMessage: some View {
        ContentUnavailableView(
            "No Budgets",
            systemImage: "tray",
            description: Text("Create a new budget to get started")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    var budgetsScrollView: some View {
        ScrollView {
             VStack(spacing: 5) {
                 ForEach(store.budgetsInVault) { budget in
                     Button {
                         store.selectBudget(budget)
                         openWindow(id: "window-main")
                         dismissWindow(id: "window-welcome")
                     } label: {
                         BudgetRowView(budget: budget)
                             .frame(maxWidth: .infinity, alignment: .leading)
                     }
                     .contextMenu {
                         Button {
                             if budget.url == nil {
                                 return
                             }
                             NSWorkspace.shared.activateFileViewerSelecting([budget.url!])
                         } label: {
                             Label("Show in Finder", systemImage: "folder")
                         }

                         Button(role: .destructive) {
                             budgetPendingRemoval = budget
                             isDeleteBudgetDialogPresented = true
                         } label: {
                             Label("Remove from Vault", systemImage: "trash")
                         }
                     }
                 }
             }
         }
    }

    var rightColumn: some View {
        VStack(alignment: .center, spacing: 10) {
            Spacer()
            
            Text("Budgets in Vault")
                .font(.headline)

            if store.isVaultNotSet {
                noBudgetsMessage
            }
            else if !store.budgetsInVaultLoaded {
                ProgressView()
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            else if store.budgetsInVault.isEmpty {
                noBudgetsMessage
            }
            else {
                budgetsScrollView
            }
            
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity)
    }
}

struct BudgetRowView: View {
    let budget: BWBudget

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(budget.title)
                .font(.headline)

            if (budget.url != nil) {
                Text(budget.url!.lastPathComponent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 5)
    }
}
