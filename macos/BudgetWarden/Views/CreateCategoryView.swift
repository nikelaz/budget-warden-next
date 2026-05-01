import SwiftUI

struct CreateCategoryView: View {
    let type: BudgetCategoryType
    let onSave: (Swift.String) -> Void
    let onCancel: () -> Void

    @State private var title = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New \(type.title) Category")
                .font(.headline)

            Form {
                TextField("Title", text: $title)
            }

            HStack {
                Spacer()

                Button("Cancel", role: .cancel) {
                    onCancel()
                }

                Button("Save") {
                    onSave(trimmedTitle)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(trimmedTitle.isEmpty)
            }
        }
        .padding()
    }

    private var trimmedTitle: Swift.String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
