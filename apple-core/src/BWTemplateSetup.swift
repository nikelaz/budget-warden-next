/*
 * Budget Warden
 * Copyright (c) 2026 Lazarov & Co EOOD
 * Author: Nikola Lazarov
 *
 * Licensed under the Source-Available Educational License.
 * See the LICENSE file in the project root for full terms.
 */

import BWCore
import Foundation
import Observation

/// Holds the answers to a template's setup questions and keeps the questions
/// and preview current. Core decides which questions appear, what each one
/// suggests, and what the answers produce; this model only records answers.
///
/// Only answers the user gave are stored. Unanswered questions use their
/// suggestions, which core recalculates from earlier answers.
@MainActor
@Observable
public final class BWTemplateSetupModel: Identifiable {
    public let templateID: String
    public private(set) var questions: [BWSetupQuestion] = []
    public private(set) var preview: BWSetupPreview?
    public private(set) var errorMessage: String?
    private var answers: [String: BWSetupAnswer] = [:]

    public init(templateID: String) {
        self.templateID = templateID
        refresh()
    }

    /// The answers to the questions currently shown, for creating the budget.
    public var currentAnswers: [BWSetupAnswer] {
        questions.compactMap { answers[$0.id] }
    }

    /// Required money questions still unanswered, such as income.
    public var unansweredRequired: [BWSetupQuestion] {
        questions.filter { $0.kind == .money && !$0.optional && answers[$0.id] == nil }
    }

    public var canCreate: Bool {
        errorMessage == nil && unansweredRequired.isEmpty
    }

    public func isAnswered(_ question: BWSetupQuestion) -> Bool {
        answers[question.id] != nil
    }

    /// The answer, or the suggestion while unanswered.
    public func value(of question: BWSetupQuestion) -> Int64 {
        answers[question.id]?.value ?? question.suggestedValue
    }

    public func choice(of question: BWSetupQuestion) -> String {
        answers[question.id]?.choice ?? question.suggestedChoice
    }

    /// Records a numeric answer; `nil` goes back to the suggestion.
    public func setValue(_ value: Int64?, for question: BWSetupQuestion) {
        answers[question.id] = value.map { BWSetupAnswer(questionId: question.id, value: $0, choice: "") }
        refresh()
    }

    public func setChoice(_ choice: String, for question: BWSetupQuestion) {
        answers[question.id] = BWSetupAnswer(questionId: question.id, value: 0, choice: choice)
        refresh()
    }

    public func createBudget(title: String) throws -> BWBudget {
        try BWCore.budgetFromTemplateSetup(templateId: templateID, title: title, answers: currentAnswers)
    }

    private func refresh() {
        let answers = Array(answers.values)
        do {
            questions = try BWCore.templateSetupQuestions(templateId: templateID, answers: answers)
            preview = try BWCore.templateSetupPreview(templateId: templateID, answers: answers)
            errorMessage = nil
        } catch let error as FfiError {
            errorMessage = error.message
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

public extension BWSetupQuestion {
    /// The text a field shows for `value`: money as an input amount, other
    /// kinds as whole numbers.
    func inputText(for value: Int64) -> String {
        kind == .money ? BWMoneyAmount(value: value).moneyInputText : String(value)
    }

    /// Parses field text into a value for this question; `nil` if invalid.
    func parseInput(_ text: String) -> Int64? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if kind == .money {
            return UInt64.parseMoneyAmount(trimmed).flatMap { Int64(exactly: $0) }
        }
        return Int64(trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "%")))
    }
}

public extension BWMoneyAmount {
    /// Formats a possibly negative amount, such as an overspent plan.
    func formattedSignedAmount(currency: BWCurrency) -> String {
        let magnitude = UInt64(value.magnitude).formattedMoneyAmount(currency: currency)
        return value < 0 ? "−\(magnitude)" : magnitude
    }
}
