/*
 * Budget Warden
 * Copyright (c) 2026 Lazarov & Co EOOD
 * Author: Nikola Lazarov
 *
 * Licensed under the Source-Available Educational License.
 * See the LICENSE file in the project root for full terms.
 */

import SwiftUI

struct BWCreateBudgetView: View {
    let store: BWStore

    @Environment(\.dismiss) private var dismiss
    @State private var title = Self.currentMonthTitle()
    @State private var selectedTemplate: BWTemplateSelection = .basic
    @State private var document: BWBudgetFileDocument?
    @State private var isExporterPresented = false
    @State private var errorMessage: String?

    private var isValid: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Budget") {
                    TextField("Title", text: $title)
                        .accessibilityIdentifier("createBudgetTitleTextField")
                }

                Section("Start From") {
                    Picker("Template", selection: $selectedTemplate) {
                        Text("Monthly Budget")
                            .tag(BWTemplateSelection.basic)

                        Text("Empty Budget")
                            .tag(BWTemplateSelection.blank)

                        if !store.recentFiles.isEmpty {
                            Divider()

                            ForEach(store.recentFiles, id: \.self) { url in
                                Text(url.deletingPathExtension().lastPathComponent)
                                    .tag(BWTemplateSelection.previous(url))
                            }
                        }
                    }
                    .accessibilityIdentifier("createBudgetTemplatePicker")
                }
            }
            .navigationTitle("New Budget")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Create", action: prepareDocument)
                        .accessibilityIdentifier("createBudgetSaveButton")
                        .disabled(!isValid)
                }
            }
        }
        .fileExporter(
            isPresented: $isExporterPresented,
            document: document,
            contentType: .budgetWardenBudget,
            defaultFilename: BWStore.fileName(for: title)
        ) { result in
            switch result {
            case .success(let url):
                Task {
                    if await store.openBudget(at: url) {
                        dismiss()
                    }
                }
            case .failure(let error):
                errorMessage = error.localizedDescription
            }
        }
        .alert("Could Not Create Budget", isPresented: errorIsPresented) {
            Button("OK") {
                errorMessage = nil
            }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func prepareDocument() {
        do {
            document = try store.makeBudgetDocument(
                title: title,
                template: selectedTemplate
            )
            isExporterPresented = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private var errorIsPresented: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    errorMessage = nil
                }
            }
        )
    }

    private static func currentMonthTitle(calendar: Calendar = .current, now: Date = Date()) -> String {
        let components = calendar.dateComponents([.year, .month], from: now)
        let titleDate = calendar.date(from: components) ?? now

        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "LLLL yyyy"

        return formatter.string(from: titleDate)
    }
}
