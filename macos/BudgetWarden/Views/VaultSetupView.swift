import SwiftUI

struct VaultSetupView: View {
    let onChooseICloud: () -> Void
    let onChooseLocal: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Choose Budget Vault")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Budget Warden stores every budget in a single vault folder named Budget Warden Budgets.")
                .foregroundStyle(.secondary)

            HStack {
                Spacer()

                Button("Cancel", role: .cancel) {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)

                Button("Local Folder") {
                    onChooseLocal()
                }

                Button("iCloud Drive") {
                    onChooseICloud()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
    }
}
