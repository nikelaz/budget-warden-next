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

/// The setup questions for a template beside a live preview of the budget
/// they produce. Core supplies the questions, so this view works for every
/// template.
struct BWTemplateSetupView: View {
    @Bindable var model: BWTemplateSetupModel
    let currency: BWCurrency

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(Array(questionGroups.enumerated()), id: \.element.first?.id) { index, group in
                        if index > 0 {
                            Divider()
                        }
                        // A question and its follow-ups stay together.
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(group, id: \.id) { question in
                                BWSetupQuestionRow(model: model, question: question, currency: currency)
                            }
                        }
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minWidth: 380)

            Divider()

            preview
                .frame(width: 280)
        }
    }

    /// Top-level questions, each followed by its follow-up questions.
    private var questionGroups: [[BWSetupQuestion]] {
        model.questions.reduce(into: []) { groups, question in
            if question.parentId.isEmpty || groups.isEmpty {
                groups.append([question])
            } else {
                groups[groups.count - 1].append(question)
            }
        }
    }

    @ViewBuilder
    private var preview: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Your Budget")
                .font(.headline)

            if let message = model.errorMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .font(.callout)
            }

            if let preview = model.preview {
                VStack(spacing: 4) {
                    summaryRow("Income", preview.income)
                    summaryRow("Planned", preview.allocated)
                    summaryRow("Left to plan", preview.unallocated)
                        .foregroundStyle(preview.unallocated.value < 0 ? .red : .primary)
                }
                .font(.callout)

                ForEach(preview.notes, id: \.self) { note in
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider()

                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(BWCategoryType.allCases, id: \.self) { type in
                            categoryGroup(type, preview.categories.filter { $0.categoryType == type })
                        }
                    }
                }
            }
        }
        .padding(16)
    }

    private func summaryRow(_ title: String, _ amount: BWMoneyAmount) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(amount.formattedSignedAmount(currency: currency))
                .monospacedDigit()
        }
    }

    @ViewBuilder
    private func categoryGroup(_ type: BWCategoryType, _ categories: [BWTemplateCategoryDefinition]) -> some View {
        if !categories.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Text(type.setupTitle)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                ForEach(categories, id: \.title) { category in
                    HStack {
                        Text(category.title)
                        Spacer()
                        Text(category.amountPlanned.formattedSignedAmount(currency: currency))
                            .monospacedDigit()
                    }
                    .font(.caption)
                    .foregroundStyle(category.amountPlanned.value == 0 ? .secondary : .primary)
                }
            }
        }
    }
}

private extension BWCategoryType {
    var setupTitle: String {
        switch self {
        case .income: "Income"
        case .expenses: "Expenses"
        case .savings: "Savings"
        case .debt: "Debt"
        }
    }
}

/// One question: its title, an input matching its kind, and help text.
private struct BWSetupQuestionRow: View {
    let model: BWTemplateSetupModel
    let question: BWSetupQuestion
    let currency: BWCurrency

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(question.title)
                .fontWeight(.medium)

            switch question.kind {
            case .choice:
                Picker(question.title, selection: Binding(
                    get: { model.choice(of: question) },
                    set: { model.setChoice($0, for: question) }
                )) {
                    ForEach(question.choices, id: \.id) { choice in
                        Text(choice.title).tag(choice.id)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            case .toggle:
                Toggle(question.title, isOn: Binding(
                    get: { model.value(of: question) == 1 },
                    set: { model.setValue($0 ? 1 : 0, for: question) }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
            default:
                BWSetupNumberField(model: model, question: question, currency: currency)
            }

            if !question.detail.isEmpty {
                Text(question.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("setupQuestion_\(question.id)")
    }
}

/// A money, percentage, or count field. While empty it shows the current
/// suggestion as its placeholder, so suggestions keep following earlier
/// answers until the user types a value.
private struct BWSetupNumberField: View {
    let model: BWTemplateSetupModel
    let question: BWSetupQuestion
    let currency: BWCurrency

    @State private var text = ""
    @State private var isInvalid = false

    var body: some View {
        HStack(spacing: 6) {
            if question.kind == .money {
                Text(currency.symbol)
                    .foregroundStyle(.secondary)
            }

            TextField(question.title, text: $text, prompt: Text(suggestion))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: question.kind == .money ? 160 : 70)
                .multilineTextAlignment(.trailing)
                .onChange(of: text) { _, newValue in
                    commit(newValue)
                }

            switch question.kind {
            case .percent:
                Text("%").foregroundStyle(.secondary)
                stepper(step: 5, range: 0...100)
            case .count:
                stepper(step: 1, range: question.minValue...100_000)
            default:
                EmptyView()
            }

            if isInvalid {
                Image(systemName: "exclamationmark.circle")
                    .foregroundStyle(.red)
                    .help("Enter a valid number.")
            } else if !model.isAnswered(question) && question.kind != .money {
                Text("Suggested")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear {
            if model.isAnswered(question) {
                text = question.inputText(for: model.value(of: question))
            }
        }
    }

    private var suggestion: String {
        question.inputText(for: question.suggestedValue)
    }

    private func stepper(step: Int, range: ClosedRange<Int64>) -> some View {
        Stepper(
            question.title,
            value: Binding(
                get: { model.value(of: question) },
                set: { text = question.inputText(for: $0) }
            ),
            in: range,
            step: step
        )
        .labelsHidden()
    }

    private func commit(_ text: String) {
        if text.trimmingCharacters(in: .whitespaces).isEmpty {
            isInvalid = false
            model.setValue(nil, for: question)
        } else if let value = question.parseInput(text) {
            isInvalid = false
            model.setValue(value, for: question)
        } else {
            isInvalid = true
        }
    }
}
