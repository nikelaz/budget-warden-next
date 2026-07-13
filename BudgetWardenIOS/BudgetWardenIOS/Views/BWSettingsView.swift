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
import SwiftUI

struct BWSettingsView: View {
    let store: BWStore
    let budget: BWBudget

    @State private var title: String
    @State private var isCurrencyPickerPresented = false
    @State private var preparedShare: BWPreparedCloudShare?
    @State private var sharingError: String?
    @State private var isPreparingShare = false
    @State private var isGoogleDriveSharePresented = false
    @FocusState private var focusedField: Field?

    init(store: BWStore, budget: BWBudget) {
        self.store = store
        self.budget = budget
        _title = State(initialValue: budget.title)
    }

    var body: some View {
        @Bindable var store = store

        List {
            Section("Budget Title") {
                TextField("Name", text: $title)
                    .focused($focusedField, equals: .name)
                    .submitLabel(.done)
                    .onSubmit {
                        Task {
                            await saveTitle()
                        }
                    }
                    .onChange(of: focusedField) { oldValue, newValue in
                        guard oldValue == .name, newValue != .name else {
                            return
                        }

                        Task {
                            await saveTitle()
                        }
                    }
            }

            Section("Currency") {
                Button {
                    isCurrencyPickerPresented = true
                } label: {
                    LabeledContent("Currency", value: title(for: store.selectedCurrency))
                }
                .buttonStyle(.plain)
            }

            if store.isICloudBudget(budget) {
                Section("Collaboration") {
                    Button {
                        prepareShare()
                    } label: {
                        Label(
                            store.sharedBudgetIDs.contains(budget.id) ? "Manage Sharing" : "Share with iCloud",
                            systemImage: "person.crop.circle.badge.plus"
                        )
                    }
                }
            }


            if store.isGoogleDriveBudget(budget) {
                Section("Collaboration") {
                    Button("Share with Google Drive", systemImage: "person.crop.circle.badge.plus") {
                        isGoogleDriveSharePresented = true
                    }
                }
            }

            BWVaultSettingsSections(store: store)
        }
        .sheet(isPresented: $isCurrencyPickerPresented) {
            CurrencySelectionView(selectedCurrency: $store.selectedCurrency)
        }
        .sheet(item: $preparedShare) { prepared in
            BWCloudSharingView(share: prepared.share)
        }
        .sheet(isPresented: $isGoogleDriveSharePresented) {
            BWGoogleDriveSharingView(budget: budget) { email in
                await store.shareGoogleDriveBudget(budget, with: email)
            }
        }
        .alert("Could Not Share Budget", isPresented: sharingErrorIsPresented) {
        } message: {
            Text(sharingError ?? "")
        }
        .overlay {
            if isPreparingShare {
                BWPreparingCloudShareView()
            }
        }
        .onChange(of: budget.id) {
            title = budget.title
        }
        .onChange(of: budget.title) {
            guard focusedField != .name else {
                return
            }

            title = budget.title
        }
        .onAppear {
            updateAutoRefreshEditorBlocker()
        }
        .onDisappear {
            store.setAutoRefreshSuspended(false, reason: "settingsEditor")
        }
        .onChange(of: isCurrencyPickerPresented) { _, _ in
            updateAutoRefreshEditorBlocker()
        }
        .onChange(of: focusedField) { _, _ in
            updateAutoRefreshEditorBlocker()
        }
    }

    private var hasAutoRefreshBlockingEditor: Bool {
        isCurrencyPickerPresented || focusedField == .name
    }

    private func updateAutoRefreshEditorBlocker() {
        store.setAutoRefreshSuspended(
            hasAutoRefreshBlockingEditor,
            reason: "settingsEditor"
        )
    }

    private func saveTitle() async {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedTitle.isEmpty else {
            title = budget.title
            return
        }

        guard trimmedTitle != budget.title else {
            title = trimmedTitle
            return
        }

        if await store.updateBudgetTitle(trimmedTitle, for: budget.id) {
            title = trimmedTitle
        }
        else {
            title = budget.title
        }
    }

    private func title(for currency: BWCurrency) -> String {
        "\(currency.rawValue) - \(currency.displayName)"
    }

    private func prepareShare() {
        guard !isPreparingShare else {
            return
        }

        guard store.isICloudEnabled else {
            sharingError = "Enable iCloud in Storage settings before sharing this budget."
            return
        }

        isPreparingShare = true

        Task {
            let result = await store.cloudRepository.prepareShare(for: budget)
            isPreparingShare = false

            switch result {
                case .failure(let error):
                    sharingError = error.localizedDescription
                case .success(let share):
                    preparedShare = BWPreparedCloudShare(share: share)
            }
        }
    }

    private var sharingErrorIsPresented: Binding<Bool> {
        Binding(
            get: { sharingError != nil },
            set: { isPresented in
                if !isPresented {
                    sharingError = nil
                }
            }
        )
    }

    private enum Field {
        case name
    }
}

private struct CurrencySelectionView: View {
    @Binding var selectedCurrency: BWCurrency

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    private var filteredCurrencies: [BWCurrency] {
        let trimmedSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedSearch.isEmpty else {
            return BWCurrency.allCases
        }

        return BWCurrency.allCases.filter { currency in
            currency.rawValue.localizedCaseInsensitiveContains(trimmedSearch)
                || currency.title.localizedCaseInsensitiveContains(trimmedSearch)
                || currency.displayName.localizedCaseInsensitiveContains(trimmedSearch)
        }
    }

    var body: some View {
        NavigationStack {
            List(filteredCurrencies, id: \.self) { currency in
                Button {
                    selectedCurrency = currency
                    dismiss()
                } label: {
                    HStack {
                        Text(title(for: currency))
                            .foregroundStyle(.primary)

                        Spacer()

                        if currency == selectedCurrency {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.tint)
                        }
                    }
                }
            }
            .navigationTitle("Currency")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "Search currencies")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) {
                        dismiss()
                    }
                }
            }
        }
    }

    private func title(for currency: BWCurrency) -> String {
        "\(currency.rawValue) - \(currency.displayName)"
    }
}
