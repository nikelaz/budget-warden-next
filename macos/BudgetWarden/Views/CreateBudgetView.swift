import Foundation
import SwiftUI

struct CreateBudgetView: View {
    let onSave: (BudgetDraft) -> Void
    let onCancel: () -> Void

    @State private var title: Swift.String
    @State private var periodStart: Date
    @State private var periodEnd: Date

    private var isValid: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && periodStart <= periodEnd
    }

    init(onSave: @escaping (BudgetDraft) -> Void, onCancel: @escaping () -> Void) {
        let defaults = BudgetDefaults.currentMonth()
        self.onSave = onSave
        self.onCancel = onCancel
        self._title = State(initialValue: defaults.title)
        self._periodStart = State(initialValue: defaults.periodStart)
        self._periodEnd = State(initialValue: defaults.periodEnd)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("New Budget")
                .font(.title2)
                .fontWeight(.semibold)

            Form {
                TextField("Title", text: $title)

                DatePicker("Period Start", selection: $periodStart, displayedComponents: .date)
                DatePicker("Period End", selection: $periodEnd, displayedComponents: .date)
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

        guard
            let start = Self.bwDate(from: periodStart),
            let end = Self.bwDate(from: periodEnd)
        else {
            return
        }

        onSave(BudgetDraft(title: trimmedTitle, periodStart: start, periodEnd: end))
    }

    private static func bwDate(from date: Date) -> BWDate? {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: date)

        guard
            let year = components.year,
            let month = components.month,
            let day = components.day
        else {
            return nil
        }

        return BWDate(year: Int32(year), month: Int32(month), day: Int32(day))
    }
}
