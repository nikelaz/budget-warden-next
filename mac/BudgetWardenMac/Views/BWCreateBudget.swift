
/* 
 * Budget Warden
 * Copyright (c) 2026 Lazarov & Co EOOD
 * Author: Nikola Lazarov
 *
 * Licensed under the Source-Available Educational License. 
 * See the LICENSE file in the project root for full terms.
 */

import BWAppleCore
import SwiftUI

struct CreateBudgetView: View {
    @EnvironmentObject var store: BWStore
    @EnvironmentObject var windowStore: BWWindowStore

    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    @State private var title: Swift.String
    @State private var selectedTemplate: BWBudgetTemplateSelection = .builtIn("basic-monthly")
    private let templateCatalog = BWCore.templateCatalog()
    @State private var recentTemplates: [BWBudgetTemplateSelection] = []
    @State private var location: BWBudgetLocation = .thisMac
    @State private var isSaving = false

    let onCreateSuccess: () -> Void

    init(onCreateSuccess: @escaping () -> Void = {}) {
        self.onCreateSuccess = onCreateSuccess
        self._title = State(initialValue: Self.currentMonthTitle())
    }

    private var isValid: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("New Budget")
                .font(.title2)
                .fontWeight(.semibold)

            Form {
                TextField("Title", text: $title)
                    .padding(.bottom, 10)
                    .accessibilityIdentifier("titleTextField")

                Picker(selection: $selectedTemplate, content: {
                    Text("Built-in templates")
                        .selectionDisabled(true)

                    ForEach(templateCatalog, id: \.id) { template in
                        Text("\(template.family) · \(template.title)")
                            .tag(BWBudgetTemplateSelection.builtIn(template.id))
                    }

                    if !recentTemplates.isEmpty {
                        Text("Previous budgets")
                            .selectionDisabled(true)

                        ForEach(recentTemplates, id: \.self) { template in
                            if case .previousBudget(let budget) = template {
                                Text(budget.title)
                                    .tag(template)
                            }
                        }
                    }
                }, label: {
                    Text("Template")
                })

                if let description = selectedTemplateDescription {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if availableLocations.count > 1 {
                    Picker("Save To", selection: $location) {
                        ForEach(availableLocations, id: \.self) { location in
                            Text(location.title).tag(location)
                        }
                    }
                    .padding(.top, 10)
                    .accessibilityIdentifier("budgetLocationPicker")
                }
            }

            HStack {
                Spacer()

                Button("Cancel", role: .cancel) {
                    windowStore.closeBudgetDialog()
                }
                .keyboardShortcut(.cancelAction)

                Button("Save") {
                    isSaving = true
                    Task(priority: .userInitiated) {
                        defer { isSaving = false }
                        if await store.createBudget(
                            title: title,
                            template: selectedTemplate,
                            location: location,
                            windowStore: windowStore
                        ) {
                            onCreateSuccess()
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid || isSaving)
            }
        }
        .padding(20)
        .task(id: store.recentFiles) {
            recentTemplates = store.recentBudgetTemplates()
        }
    }

    private var availableLocations: [BWBudgetLocation] {
        BWBudgetLocation.allCases.filter { location in
            switch location {
            case .thisMac: true
            case .iCloud: store.iCloud.isAvailable
            case .googleDrive: store.googleDrive.isSignedIn
            }
        }
    }

    private var selectedTemplateDescription: String? {
        guard case .builtIn(let id) = selectedTemplate else { return nil }
        return templateCatalog.first(where: { $0.id == id })?.description
    }

    private static func currentMonthTitle(calendar: Calendar = .current, now: Date = Date()) -> Swift.String {
        let components = calendar.dateComponents([.year, .month], from: now)
        let titleDate = calendar.date(from: components) ?? now

        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "LLLL yyyy"

        return formatter.string(from: titleDate)
    }
}
