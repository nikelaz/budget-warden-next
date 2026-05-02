import SwiftUI

struct CreateCategoryView: View {
    let type: BudgetCategoryType
    let onSave: (Swift.String, UInt64) -> Void
    let onCancel: () -> Void

    @State private var title = ""
    @State private var plannedAmount = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New \(type.title) Category")
                .font(.headline)

            Form {
                TextField("Title", text: $title)

                TextField("Planned Amount", text: $plannedAmount)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                Spacer()

                Button("Cancel", role: .cancel) {
                    onCancel()
                }

                Button("Save") {
                    onSave(trimmedTitle, parsedPlannedAmount ?? 0)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(trimmedTitle.isEmpty || parsedPlannedAmount == nil)
            }
        }
        .padding()
    }

    private var trimmedTitle: Swift.String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var parsedPlannedAmount: UInt64? {
        let trimmedAmount = plannedAmount.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedAmount.isEmpty else {
            return 0
        }

        return UInt64(trimmedAmount)
    }
}
