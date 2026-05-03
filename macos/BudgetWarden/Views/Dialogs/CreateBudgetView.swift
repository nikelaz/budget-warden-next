import Foundation
import SwiftUI

struct CreateBudgetView: View {
    let onSave: (BudgetDraft) -> Void
    let onCancel: () -> Void

    @State private var title: Swift.String

    private var isValid: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    init(onSave: @escaping (BudgetDraft) -> Void, onCancel: @escaping () -> Void) {
        let defaults = BudgetDefaults.currentMonth()
        self.onSave = onSave
        self.onCancel = onCancel
        self._title = State(initialValue: defaults.title)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("New Budget")
                .font(.title2)
                .fontWeight(.semibold)

            Form {
                TextField("Title", text: $title)
            }

            HStack {
                Spacer()

                Button("Cancel", role: .cancel) {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)

                Button("Save") {
                    saveBudget()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
            }
        }
        .padding()
    }

    private func saveBudget() {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        onSave(BudgetDraft(title: trimmedTitle))
    }
}
