# Apple Shortcuts and Siri

Budget Warden exposes its budget actions as App Intents on macOS and iOS. After installing or updating the app, open it once so Apple can register its App Shortcuts. You can then invoke the suggested phrases with Siri or add the actions in the Shortcuts app.

## Available actions

- List, create, rename, and delete budgets. New budgets are saved in the app's `Documents/Budget Warden` folder using a built-in template.
- List categories by budget and type, including planned and actual amounts.
- Create, update, and delete categories.
- List transactions by budget, category, or search text.
- Create, update, move, and delete transactions.
- Read a budget summary with income, planned and actual spending, planned savings, and the amount left to budget.

Budget amounts use the currency selected in Budget Warden and accept up to two decimal places. Siri and Shortcuts ask for confirmation before deleting a budget, category, or transaction. Deleting a budget removes its `.budget` file; deleting a category also deletes its transactions.

## Using your budgets

The budget picker shows the current budget and files you have opened recently in Budget Warden. Open a `.budget` file in the app first if it is not offered by Siri or Shortcuts. Intent changes are saved to that file; creating a budget through Siri or a shortcut creates a new file in the app's documents folder.

To build a reusable workflow, add Budget Warden actions in Shortcuts and pass their returned budget, category, or transaction entities into later actions. The summary, category, and transaction browsing actions have suggested Siri phrases. Other actions, including List Budgets, are available in Shortcuts.

Examples of the suggested Siri phrasing:

- “Show the Vacation budget summary in Budget Warden.”
- “Delete the Vacation budget in Budget Warden.”
- “Add a category to the Monthly budget in Budget Warden.”
- “Add a transaction to the Monthly budget in Budget Warden.”
- “Manage transactions in the Monthly budget in Budget Warden.”

Siri asks for remaining required details, such as names and amounts. Category and transaction selections must belong to the selected budget.

For a Siri routing check, say “Show my budget summary in Budget Warden.” Siri should ask you to choose a budget. This trigger does not depend on recognizing a budget name. The app refreshes Siri’s suggested budget names when files are opened or saved.
