/*
 * Budget Warden
 * Copyright (c) 2026 Lazarov & Co EOOD
 * Author: Nikola Lazarov
 *
 * Licensed under the Source-Available Educational License.
 * See the LICENSE file in the project root for full terms.
 */

import SwiftUI

struct BWRootView: View {
    @State private var store = BWStore()
    @State private var navigationPath: [UUID] = []
    @State private var isCreateBudgetPresented = false
    @State private var isOpenBudgetPresented = false

    var body: some View {
        NavigationStack(path: $navigationPath) {
            BWBudgetListView(
                store: store,
                createBudget: { isCreateBudgetPresented = true },
                openBudget: { isOpenBudgetPresented = true },
                openRecent: openBudget
            )
            .navigationDestination(for: UUID.self, destination: destination)
        }
        .onChange(of: store.selectedBudgetID) { _, budgetID in
            if let budgetID {
                navigationPath = [budgetID]
            } else {
                navigationPath = []
            }
        }
        .task {
            await store.migrateLegacyBudgetsIfNeeded()
        }
        .onOpenURL(perform: openBudget)
        .fileImporter(
            isPresented: $isOpenBudgetPresented,
            allowedContentTypes: [.budgetWardenBudget],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    openBudget(url)
                }
            case .failure(let error):
                store.errorMessage = error.localizedDescription
            }
        }
        .sheet(isPresented: $isCreateBudgetPresented) {
            BWCreateBudgetView(store: store)
        }
        .alert("Error", isPresented: errorIsPresented) {
            Button("OK") {
                store.errorMessage = nil
            }
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
                createBudget: { isCreateBudgetPresented = true },
                openBudget: { isOpenBudgetPresented = true },
                closeBudget: closeBudget
            )
        } else {
            ContentUnavailableView("Budget Not Found", systemImage: "doc.badge.questionmark")
        }
    }

    private func openBudget(_ url: URL) {
        Task {
            _ = await store.openBudget(at: url)
        }
    }

    private func closeBudget() {
        store.closeBudget()
        navigationPath = []
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
