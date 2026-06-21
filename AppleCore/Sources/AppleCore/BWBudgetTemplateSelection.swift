/*
 * Budget Warden
 * Copyright (c) 2026 Lazarov & Co EOOD
 * Author: Nikola Lazarov
 *
 * Licensed under the Source-Available Educational License.
 * See the LICENSE file in the project root for full terms.
 *
 */

import Foundation

public enum BWBudgetTemplateSelection: Hashable, Sendable {
    case basic
    case blank
    case previous(URL)
}
