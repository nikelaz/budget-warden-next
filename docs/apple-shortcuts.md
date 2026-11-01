# Apple Shortcuts and Siri

Budget Warden exposes its budget actions as App Intents on macOS and iOS. After installing or updating the app, open it once so Apple can register its App Shortcuts. You can then invoke the suggested phrases with Siri or add the actions in the Shortcuts app.

## Available actions

- List, create, rename, and delete budgets. New budgets use a built-in template and the default currency, and are saved in the same `Budgets` folder as budgets created by MCP clients.
- List categories by budget and type, including planned and actual amounts.
- Create, update, and delete categories.
- List transactions by budget, category, or search text.
- Create, update, move, and delete transactions.
- Read a budget summary with income, planned and actual spending, planned savings, and the amount left to budget.

Amounts are in the budget's own currency and accept up to two decimal places. Siri and Shortcuts ask for confirmation before deleting a budget, category, or transaction. Deleting a budget removes its `.budget` file; deleting a category also deletes its transactions.

## Using your budgets

The budget picker shows the open budget, budgets you have opened recently, your iCloud Drive budgets, and your Google Drive budgets. Open a `.budget` file in the app first if it is not offered by Siri or Shortcuts.

Actions save straight to the budget's file and never change which budget the app has open; if the app has that budget open, it reloads it. Changes to Google Drive budgets sync like edits made in the app. Google Drive and iCloud Drive budgets that are not on the device yet are downloaded when an action needs them; actions that search across all budgets only look at budgets already on the device. Google Drive budgets cannot be deleted from Shortcuts.

Budget Warden reads a budget file only when it changed since it was last read, and each category or transaction remembers its budget, so choosing one reads only that budget's file.

To build a reusable workflow, add Budget Warden actions in Shortcuts and pass their returned budget, category, or transaction entities into later actions. The summary, category, and transaction browsing actions have suggested Siri phrases. Other actions, including List Budgets, are available in Shortcuts.

Examples of the suggested Siri phrasing:

- “Show the Vacation budget summary in Budget Warden.”
- “Delete the Vacation budget in Budget Warden.”
- “Add a category to the Monthly budget in Budget Warden.”
- “Add a transaction to the Monthly budget in Budget Warden.”
- “Manage transactions in the Monthly budget in Budget Warden.”

Siri asks for remaining required details, such as names and amounts. Category and transaction selections must belong to the selected budget.

For a Siri routing check, say “Show my budget summary in Budget Warden.” Siri should ask you to choose a budget. This trigger does not depend on recognizing a budget name. The app refreshes Siri’s suggested budget names when files are opened or saved.
