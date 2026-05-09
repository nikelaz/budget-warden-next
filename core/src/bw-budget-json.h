/* 
 * Budget Warden Core
 * Copyright (c) 2026 Lazarov & Co EOOD
 * Author: Nikola Lazarov
 *
 * Licensed under the Source-Available Educational License. 
 * See the LICENSE file in the project root for full terms.
 *
 */

#ifndef BW_BUDGET_JSON_H
#define BW_BUDGET_JSON_H

#include "bw-budget.h"

BWString bw_budget_to_json_str(const BWBudget *budget, BWArena *json_arena);
BWResult bw_budget_from_json_str(BWBudget *budget, const char *budget_json);

#endif
