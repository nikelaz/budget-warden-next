/*
 * Budget Warden
 * Copyright (c) 2026 Lazarov & Co EOOD
 * Author: Nikola Lazarov
 *
 * Licensed under the Source-Available Educational License.
 * See the LICENSE file in the project root for full terms.
 *
 */

import AppleCore
import SwiftUI

struct BWRootView: View {
    @State private var store = BWAppStore()
    @State private var navigationPath: [UUID] = []
    @State private var activeSheet: BWRootSheet?
    @Namespace private var budgetNavigationNamespace

    var body: some View {
        NavigationStack(path: $navigationPath) {
            BWListView(
                store: store,
                createBudget: showCreateBudget,
                configureVault: showConfigureVault,
                navigationTransitionNamespace: budgetNavigationNamespace
            )
                .navigationDestination(for: UUID.self, destination: destination)
        }
        .task {
            await store.loadBudgets()
            openInitialBudget()
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
            store.openBudget(at: url)
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
                case .createBudget:
                    BWCreateBudgetView(store: store)
                case .configureVault:
                    BWConfigureVaultView(store: store)
            }
        }
        .alert("Could Not Open Budget", isPresented: errorIsPresented) {
        } message: {
            Text(store.errorMessage ?? "")
        }
    }

    @ViewBuilder
    private func destination(for budgetID: UUID) -> some View {
        if store.budget(withID: budgetID) != nil {
            BWWorkspaceView(
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
