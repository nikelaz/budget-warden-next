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
import BudgetWardenAppleCore
import CloudKit
import GoogleSignIn

private let WINDOW_WIDTH: CGFloat = 760
private let WINDOW_HEIGHT: CGFloat = 420

struct BWWindowWelcome: Scene { 
    @EnvironmentObject var store: BWStore

    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.scenePhase) private var scenePhase

    @StateObject private var windowStore = BWWindowStore()

    @State private var isDeleteBudgetDialogPresented: Bool = false
    @State private var budgetPendingRemoval: BWBudget? = nil
    @State private var isPreparingShare = false
    @State private var googleDriveShareBudget: BWBudget?

    var body: some Scene {
        Window("Welcome Window", id: "window-welcome") {
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
            .overlay {
                if isPreparingShare {
                    BWPreparingCloudShareView()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .budgetWardenAcceptedCloudShare)) { notification in
                guard let recordID = notification.object as? CKRecord.ID else {
                    return
                }

                Task {
                    await openAcceptedCloudShare(recordID: recordID)
                }
            }
            .containerBackground(.regularMaterial, for: .window)
            .task {
                await store.loadBudgetsFromVault()
                store.setAutoRefreshActive(scenePhase == .active)

                if let recordID = BWPendingCloudShare.recordID {
                    await openAcceptedCloudShare(recordID: recordID)
                }
            }
            .onOpenURL { url in
                guard !GIDSignIn.sharedInstance.handle(url) else { return }
                Task(priority: .userInitiated) {
                    if await store.openBudget(at: url, windowStore: windowStore) {
                        openWindow(id: "window-main")
                        dismissWindow(id: "window-welcome")
                    }
                }
            }
            .onAppear {
                updateAutoRefreshDialogBlocker()
            }
            .onDisappear {
                store.setAutoRefreshSuspended(false, reason: "welcomeWindowDialog")
            }
            .onChange(of: scenePhase) { _, phase in
                store.setAutoRefreshActive(phase == .active)
            }
            .onChange(of: hasAutoRefreshBlockingDialog) { _, _ in
                updateAutoRefreshDialogBlocker()
            }
            .alert("Error", isPresented: $windowStore.isErrorState) {
                Button("OK") {
                    windowStore.clearError()
                }
            } message: {
                Text(windowStore.errorMessage)
            }
            .alert("Vault Warning", isPresented: Binding(
                get: { store.vaultWarningMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        store.clearVaultWarning()
                    }
                }
            )) {
                Button("OK") {
                    store.clearVaultWarning()
                }
            } message: {
                Text(store.vaultWarningMessage ?? "")
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

                    Task(priority: .userInitiated) {
                        await store.removeBudget(
                            url: budgetUrl,
                            windowStore: windowStore
                        )
                        budgetPendingRemoval = nil
                    }
                }
                .accessibilityLabel("MoveToTrashRemoveBudgetConfirm")

                Button("Cancel", role: .cancel) {
                    budgetPendingRemoval = nil
                }
            } message: { budget in
                if let budgetUrl = budget.url {
                    Text("Move \(budgetUrl.lastPathComponent) to Trash?")
                }
                else {
                    Text("Move budget to trash?")
                }
            }
            .sheet(isPresented: $windowStore.isBudgetDialogOpen) {
                CreateBudgetView(
                    onCreateSuccess: openMainOnBudgetCreation
                )
                .environmentObject(windowStore)
                .frame(minWidth: 420)
            }
            .sheet(item: $googleDriveShareBudget) { budget in
                BWGoogleDriveSharingView(budget: budget) { email in
                    await store.shareGoogleDriveBudget(budget, with: email, windowStore: windowStore)
                }
            }
            .sheet(isPresented: $windowStore.isVaultConfigDialogOpen) {
                ConfigureVaultView() 
                .environmentObject(store)
                .environmentObject(windowStore)
                .frame(minWidth: 420)
            }
            .sheet(isPresented: $windowStore.isPreferencesDialogOpen) {
                BWPreferencesView(
                    selectedCurrency: $store.selectedCurrency,
                    onClose: {
                        windowStore.closePreferencesDialog()
                    }
                )
                .frame(minWidth: 420)
            }
        }
        .defaultSize(width: WINDOW_WIDTH, height: WINDOW_HEIGHT)
        .defaultLaunchBehavior(.presented)
        .restorationBehavior(.disabled)
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)  
        .commands {
            BWCommands(windowStore: windowStore)
        }
    }

    private var hasAutoRefreshBlockingDialog: Bool {
        windowStore.isBudgetDialogOpen
            || windowStore.isVaultConfigDialogOpen
            || windowStore.isPreferencesDialogOpen
            || windowStore.isErrorState
            || isDeleteBudgetDialogPresented
            || isPreparingShare
    }

    private func updateAutoRefreshDialogBlocker() {
        store.setAutoRefreshSuspended(
            hasAutoRefreshBlockingDialog,
            reason: "welcomeWindowDialog"
        )
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
                    Task(priority: .userInitiated) {
                        if await store.openBudget(windowStore: windowStore) {
                            openWindow(id: "window-main")
                            dismissWindow(id: "window-welcome")
                        }
                    }
                }
                
                Button("Configure Vault", systemImage: "externaldrive") {
                    windowStore.openVaultConfigDialog()
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
            VStack(alignment: .leading, spacing: 14) {
                if !store.iCloudBudgets.isEmpty {
                    budgetSection(
                        title: "iCloud",
                        budgets: store.iCloudBudgets,
                        canShareWithICloud: true,
                        canShareWithGoogleDrive: false
                    )
                }

                if !store.googleDriveBudgets.isEmpty {
                    budgetSection(
                        title: "Google Drive",
                        budgets: store.googleDriveBudgets,
                        canShareWithICloud: false,
                        canShareWithGoogleDrive: true
                    )
                }

                if !store.localBudgets.isEmpty {
                    budgetSection(
                        title: "Local",
                        budgets: store.localBudgets,
                        canShareWithICloud: false,
                        canShareWithGoogleDrive: false
                    )
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private func budgetSection(
        title: String,
        budgets: [BWBudget],
        canShareWithICloud: Bool,
        canShareWithGoogleDrive: Bool
    ) -> some View {
        Text(title)
            .font(.headline)
            .frame(maxWidth: .infinity, alignment: .leading)

        VStack(spacing: 5) {
            ForEach(budgets) { budget in
                Button {
                    store.selectBudget(budget)
                    openWindow(id: "window-main")
                    dismissWindow(id: "window-welcome")
                } label: {
                    BudgetRowView(
                        budget: budget,
                        isShared: (canShareWithICloud && store.sharedBudgetIDs.contains(budget.id))
                            || (canShareWithGoogleDrive && store.googleDriveSharedBudgetIDs.contains(budget.id))
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contextMenu {
                    if canShareWithICloud {
                        Button {
                            shareBudget(budget)
                        } label: {
                            Label(
                                store.sharedBudgetIDs.contains(budget.id) ? "Manage Sharing" : "Share with iCloud",
                                systemImage: "person.crop.circle.badge.plus"
                            )
                        }
                    }


                    if canShareWithGoogleDrive {
                        Button {
                            googleDriveShareBudget = budget
                        } label: {
                            Label("Share with Google Drive", systemImage: "person.crop.circle.badge.plus")
                        }
                    }

                    Button {
                        guard let budgetUrl = budget.url else {
                            return
                        }

                        NSWorkspace.shared.activateFileViewerSelecting([budgetUrl])
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
                .accessibilityLabel("Button_\(budget.title)")
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

    func openMainOnBudgetCreation() {
        windowStore.closeBudgetDialog()
        
        // This DispatchQueue is needed, because closeBudgetDialog is async and cannot be awaited
        // sheet closing is managed internally by SwiftUI, we just flip a flag state variable
        // The DispatchQueue allows us to queue something to be executed after that
        DispatchQueue.main.async {
            dismissWindow(id: "window-welcome")
            openWindow(id: "window-main")
        }
    }

    private func shareBudget(_ budget: BWBudget) {
        guard !isPreparingShare else {
            return
        }

        guard store.isICloudEnabled else {
            windowStore.setError(.iCloudUnavailable())
            return
        }

        isPreparingShare = true

        Task {
            let result = await store.cloudRepository.prepareShare(for: budget)
            isPreparingShare = false

            switch result {
                case .failure(let error):
                    windowStore.setError(error)
                case .success(let share):
                    BWMacCloudSharing.shared.present(share)
            }
        }
    }

    private func openAcceptedCloudShare(recordID: CKRecord.ID) async {
        guard await store.openAcceptedCloudShare(recordID: recordID) else {
            return
        }

        BWPendingCloudShare.clear(recordID: recordID)
        openWindow(id: "window-main")
        dismissWindow(id: "window-welcome")
    }
}

struct BudgetRowView: View {
    let budget: BWBudget
    let isShared: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(budget.title)
                .font(.headline)

            if isShared {
                Text("Shared")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let budgetUrl = budget.url {
                Text(budgetUrl.lastPathComponent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 5)
    }
}
