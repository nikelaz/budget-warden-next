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

struct PreferencesView: View {
    @Binding var selectedCurrency: AppCurrency
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Preferences")
                .font(.headline)

            Form {
                Picker("Currency", selection: $selectedCurrency) {
                    ForEach(AppCurrency.allCases) { currency in
                        Text(currency.displayName)
                            .tag(currency)
                    }
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
