import Foundation
import SwiftUI

struct CreateBudgetView: View {
    let onSave: (BudgetDraft) -> Void
    let onCancel: () -> Void

    @State private var title: Swift.String

    enum BudgetTemplate: String, CaseIterable, Identifiable {
        case basic, blank
        var id: Self { self }
    }

    @State private var selectedTemplate: BudgetTemplate = .basic 

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

            // Todo(Niki): Finish the template implementation
            // Todo(Niki) 2: Add previous budgets in vault as templates in the dropdown
            Form {
                TextField("Title", text: $title)
                    .accessibilityIdentifier("budget-title-field")
                    .padding(.bottom, 10);

                Picker(selection: $selectedTemplate, content: {
                    Text("Basic Budget")
                        .tag(BudgetTemplate.basic)

                    Text("Blank Budget")
                        .tag(BudgetTemplate.blank)
                }, label: {
                    Text("Template")
                })
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
