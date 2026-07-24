/* 
 * Budget Warden
 * Copyright (c) 2026 Lazarov & Co EOOD
 * Author: Nikola Lazarov
 *
 * Licensed under the Source-Available Educational License. 
 * See the LICENSE file in the project root for full terms.
 */

import SwiftUI
import BWCore

struct BWPreferencesView: View {
    @Binding var selectedCurrency: BWCurrency
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Preferences")
                .font(.headline)

            Form {
                Picker("Currency", selection: $selectedCurrency) {
                    ForEach(BWCurrency.allCases, id: \.self) { currency in
                        Text(title(for: currency))
                            .tag(currency)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 280)
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

    private func title(for currency: BWCurrency) -> String {
        "\(currency.rawValue) - \(currency.displayName)"
    }
}
