/* 
 * Budget Warden Core
 * Copyright (c) 2026 Lazarov & Co EOOD
 * Author: Nikola Lazarov
 *
 * Licensed under the Source-Available Educational License. 
 * See the LICENSE file in the project root for full terms.
 *
 */

import SwiftUI
import AppKit

struct PreferencesView: View {
    @Binding var selectedCurrency: AppCurrency
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Preferences")
                .font(.headline)

            Form {
                LabeledContent("Currency") {
                    CurrencyComboBox(selectedCurrency: $selectedCurrency)
                }
            }

            HStack {
                Spacer()

                Button("Done") {
                    onClose()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
    }
}

private struct CurrencyComboBox: NSViewRepresentable {
    @Binding var selectedCurrency: AppCurrency

    private let currencies = AppCurrency.allCases

    func makeNSView(context: Context) -> NSComboBox {
        let comboBox = NSComboBox()
        comboBox.usesDataSource = false
        comboBox.completes = true
        comboBox.isEditable = true
        comboBox.numberOfVisibleItems = 12
        comboBox.delegate = context.coordinator
        comboBox.addItems(withObjectValues: currencies.map(Self.title(for:)))
        comboBox.setAccessibilityLabel("Currency")
        comboBox.setContentHuggingPriority(.defaultLow, for: .horizontal)
        comboBox.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        return comboBox
    }

    func updateNSView(_ comboBox: NSComboBox, context: Context) {
        context.coordinator.selectedCurrency = $selectedCurrency

        let selectedTitle = Self.title(for: selectedCurrency)
        if comboBox.stringValue != selectedTitle {
            comboBox.stringValue = selectedTitle
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(currencies: currencies, selectedCurrency: $selectedCurrency)
    }

    nonisolated private static func title(for currency: AppCurrency) -> Swift.String {
        "\(currency.rawValue) - \(currency.displayName)"
    }

    final class Coordinator: NSObject, NSComboBoxDelegate {
        let currencies: [AppCurrency]
        var selectedCurrency: Binding<AppCurrency>

        init(currencies: [AppCurrency], selectedCurrency: Binding<AppCurrency>) {
            self.currencies = currencies
            self.selectedCurrency = selectedCurrency
        }

        func comboBox(_ comboBox: NSComboBox, completedString string: String) -> String? {
            let trimmedString = string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedString.isEmpty else {
                return nil
            }

            return currencies
                .map(CurrencyComboBox.title(for:))
                .first { title in
                    title.localizedCaseInsensitiveContains(trimmedString)
                }
        }

        func comboBoxSelectionDidChange(_ notification: Notification) {
            guard let comboBox = notification.object as? NSComboBox else {
                return
            }

            selectCurrency(matching: comboBox.stringValue)
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let comboBox = notification.object as? NSComboBox else {
                return
            }

            if !selectCurrency(matching: comboBox.stringValue) {
                comboBox.stringValue = CurrencyComboBox.title(for: selectedCurrency.wrappedValue)
            }
        }

        @discardableResult
        private func selectCurrency(matching text: String) -> Bool {
            let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)

            guard
                let currency = currencies.first(where: { currency in
                    currency.rawValue.localizedCaseInsensitiveCompare(trimmedText) == .orderedSame ||
                        currency.rawValue.localizedCaseInsensitiveCompare(trimmedText.prefix(currency.rawValue.count)) == .orderedSame ||
                        CurrencyComboBox.title(for: currency).localizedCaseInsensitiveCompare(trimmedText) == .orderedSame
                })
            else {
                return false
            }

            selectedCurrency.wrappedValue = currency
            return true
        }
    }
}
