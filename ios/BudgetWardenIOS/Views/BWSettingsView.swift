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

struct BWSettingsView: View {
    let store: BWStore
    let budget: BWBudget

    @State private var title: String
    @State private var isCurrencyPickerPresented = false
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
                        Task { await saveTitle() }
                    }
                    .onChange(of: focusedField) { oldValue, newValue in
                        guard oldValue == .name, newValue != .name else { return }
                        Task { await saveTitle() }
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

            if let path = budget.url {
                let fileURL = URL(fileURLWithPath: path)

                Section("File") {
                    LabeledContent("Name", value: fileURL.lastPathComponent)
                    Text(BWFileLocationFormatter.displayPath(for: fileURL))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
        .sheet(isPresented: $isCurrencyPickerPresented) {
            CurrencySelectionView(selectedCurrency: $store.selectedCurrency)
        }
        .onChange(of: budget.id) {
            title = budget.title
        }
        .onChange(of: budget.title) {
            guard focusedField != .name else { return }
            title = budget.title
        }
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
        } else {
            title = budget.title
        }
    }

    private func title(for currency: BWCurrency) -> String {
        "\(currency.rawValue) - \(currency.displayName)"
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
        guard !trimmedSearch.isEmpty else { return BWCurrency.allCases }

        return BWCurrency.allCases.filter { currency in
            currency.rawValue.localizedCaseInsensitiveContains(trimmedSearch)
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
        "\(currency.displayName) - \(currency.symbol)"
    }
}
