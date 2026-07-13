/*
 * Budget Warden
 * Copyright (c) 2026 Lazarov & Co EOOD
 * Author: Nikola Lazarov
 *
 * Licensed under the Source-Available Educational License.
 * See the LICENSE file in the project root for full terms.
 *
 */

import BudgetWardenAppleCore
import CloudKit
import GoogleSignIn
import SwiftUI

struct BWRootView: View {
    @Environment(\.scenePhase) private var scenePhase

    @State private var store = BWStore()
    @State private var navigationPath: [UUID] = []
    @State private var activeSheet: BWRootSheet?
    @Namespace private var budgetNavigationNamespace

    var body: some View {
        NavigationStack(path: $navigationPath) {
            BWBudgetListView(
                store: store,
                createBudget: showCreateBudget,
                configureVault: showConfigureVault,
                navigationTransitionNamespace: budgetNavigationNamespace
            )
                .navigationDestination(for: UUID.self, destination: destination)
        }
        .task {
            await store.loadBudgets()

            if let recordID = BWPendingCloudShare.recordID {
                await openAcceptedCloudShare(recordID: recordID)
            }

            openInitialBudget()
            updateAutoRefreshActivity(for: scenePhase)
        }
        .onChange(of: scenePhase) { _, phase in
            updateAutoRefreshActivity(for: phase)
        }
        .onChange(of: store.selectedBudgetID) { _, selectedBudgetID in
            guard let selectedBudgetID else {
                navigationPath = []
                return
            }

            if navigationPath.last != selectedBudgetID {
                navigationPath = [selectedBudgetID]
            }
        }
        .onChange(of: navigationPath) { _, path in
            guard let budgetID = path.last, store.selectedBudgetID != budgetID else {
                return
            }

            store.selectBudget(withID: budgetID)
        }
        .onOpenURL { url in
            guard !GIDSignIn.sharedInstance.handle(url) else { return }
            Task {
                await store.openBudget(at: url)
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
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
                case .createBudget:
                    BWCreateBudgetView(store: store)
                case .configureVault:
                    BWConfigureVaultView(store: store)
            }
        }
        .onChange(of: activeSheet) { _, sheet in
            store.setAutoRefreshSuspended(sheet != nil, reason: "rootSheet")
        }
        .alert("Could Not Open Budget", isPresented: errorIsPresented) {
        } message: {
            Text(store.errorMessage ?? "")
        }
    }

    @ViewBuilder
    private func destination(for budgetID: UUID) -> some View {
        if store.budget(withID: budgetID) != nil {
            BWMainTabsView(
                store: store,
                budgetID: budgetID,
                createBudget: showCreateBudget,
                showBudgetList: showBudgetList
            )
            .navigationTransition(.zoom(sourceID: budgetID, in: budgetNavigationNamespace))
        }
        else {
            ContentUnavailableView("Budget Not Found", systemImage: "folder.badge.questionmark")
        }
    }

    private func openInitialBudget() {
        guard navigationPath.isEmpty, let selectedBudgetID = store.selectedBudgetID else {
            return
        }

        navigationPath = [selectedBudgetID]
    }

    private func updateAutoRefreshActivity(for phase: ScenePhase) {
        let isActive = phase == .active
        store.setAutoRefreshActive(isActive)
    }

    private func openAcceptedCloudShare(recordID: CKRecord.ID) async {
        guard await store.openAcceptedCloudShare(recordID: recordID) else {
            return
        }

        BWPendingCloudShare.clear(recordID: recordID)
    }

    private func showCreateBudget() {
        activeSheet = .createBudget
    }

    private func showBudgetList() {
        navigationPath = []
    }

    private func showConfigureVault() {
        activeSheet = .configureVault
    }

    private var errorIsPresented: Binding<Bool> {
        Binding(
            get: { store.errorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    store.errorMessage = nil
                }
            }
        )
    }
}

private enum BWRootSheet: Hashable, Identifiable {
    case createBudget
    case configureVault

    var id: Self {
        self
    }
}
