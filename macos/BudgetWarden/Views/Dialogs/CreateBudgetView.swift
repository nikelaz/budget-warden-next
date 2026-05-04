import Foundation
import SwiftUI

struct CreateBudgetView: View {
    @ObservedObject var store: BudgetStore
    let onSave: (BudgetDraft) -> Void
    let onCancel: () -> Void
    var basicTemplateUrl: String;

    @State private var title: Swift.String

    @State private var selectedTemplate: String = "TemplateBasic"

    private var isValid: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    init(store: BudgetStore, onSave: @escaping (BudgetDraft) -> Void, onCancel: @escaping () -> Void) {
        let defaults = BudgetDefaults.currentMonth()
        self.store = store
        self.onSave = onSave
        self.onCancel = onCancel
        self._title = State(initialValue: defaults.title)
        self.basicTemplateUrl = ""
        self.basicTemplateUrl = getBasicTemplateUrl()
    }

    private func getBasicTemplateUrl() -> String {
        guard let url = Bundle.main.url(forResource: "basic-budget", withExtension: "budget") else {
            return ""
        }

        return url.path
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("New Budget")
                .font(.title2)
                .fontWeight(.semibold)

            Form {
                TextField("Title", text: $title)
                    .accessibilityIdentifier("budget-title-field")
                    .padding(.bottom, 10);

                Picker(selection: $selectedTemplate, content: {
                    Text("Templates") 
                        .selectionDisabled(true)

                    Text("Basic budget (recommended)")
                        .tag("TemplateBasic")

                    Text("Blank budget")
                        .tag("TemplateBlank")

                    Text("Previous budget") 
                        .selectionDisabled(true)

                    ForEach(store.budgets) { budget in
                        Text(budget.title)
                            .tag(budget.url.path)
                    }
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
        
        var template = ""
        
        if (selectedTemplate == "TemplateBasic") {
            template = basicTemplateUrl
        }
        else if (selectedTemplate != "TemplateBlank" && selectedTemplate != "") {
            template = selectedTemplate
        }
        
        onSave(BudgetDraft(title: trimmedTitle, templateUrl: template))
    }
}
