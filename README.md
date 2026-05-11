# Budget Warden

Budget Warden is a source-available SwiftUI macOS budgeting app. It stores budgets as plain JSON `.budget` files and keeps the budget model, file loading, and user experience in the Swift app.

## Features

- Create and manage local budget files.
- Store budgets in a configurable vault folder, including an iCloud Drive location.
- Open standalone `.budget` files in place.
- Track income, expenses, savings, debt categories, and transactions.
- Reorder and edit categories.
- View budget, reporting, and transactions screens.
- Choose an ISO currency for display.
- Start from the included basic budget template.

## Repository Layout

```text
.
├── macos/      SwiftUI macOS app and Xcode test targets
├── templates/  Starter .budget templates
└── LICENSE     Source-available educational license
```

## Requirements

- macOS
- Xcode with `xcodebuild`
The macOS project currently targets macOS `26.4` and uses Swift `5.0` settings in the Xcode project.

## Development

Build the macOS app:

```sh
cd macos
./build.sh
```

Open the app project in Xcode:

```sh
open macos/BudgetWarden.xcodeproj
```

## Budget Files

Budget files use the `.budget` extension and contain JSON. A budget has a title, categories, planned and actual amounts, accumulated amounts, category types, and transactions.

The included starter template is available at:

```text
templates/basic-budget.budget
```

Amounts are stored as integer minor units. For example, `480000` represents `4,800.00` in a two-decimal currency.

## Native App Architecture

The SwiftUI app is organized around:

- `Budget`, the single Swift model for budget data, JSON serialization, category logic, totals, and transactions.
- `BWStore`, which coordinates app state, user actions, and selected-budget persistence.
- `BWBudgetVault`, which manages the configured storage folder and security-scoped access.
- SwiftUI views for welcome, budget, reporting, transactions, dialogs, and shared layout.

## License

This repository is source-available for educational, research, and reference purposes only. Building, running, using, redistributing, or commercially using the software requires a valid commercial license from Lazarov & Co EOOD.

See [LICENSE](LICENSE) for the full terms.
