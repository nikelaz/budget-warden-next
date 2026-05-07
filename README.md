# Budget Warden

Budget Warden is a source-available macOS budgeting app backed by a small C core. It stores budgets as plain JSON `.budget` files, keeps the budgeting logic in `core/`, and exposes the user experience through a native SwiftUI app in `macos/`.

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
├── core/       C17 budgeting engine, JSON serialization, and core tests
├── macos/      SwiftUI macOS app and Xcode test targets
├── templates/  Starter .budget templates
└── LICENSE     Source-available educational license
```

## Requirements

- macOS
- Xcode with `xcodebuild`
- Clang with C17 support

The macOS project currently targets macOS `26.4` and uses Swift `5.0` settings in the Xcode project.

## Development

The project has separate test scripts for the C core and macOS app.

Run the C core tests:

```sh
cd core
./test.sh
```

Run the macOS app tests:

```sh
cd macos
./test.sh
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

- `BudgetStore`, which coordinates app state and user actions.
- `BudgetRepository`, which reads, writes, and mutates `.budget` files through the C core.
- `BudgetVault`, which manages the configured storage folder and security-scoped access.
- SwiftUI views for welcome, budget, reporting, transactions, dialogs, and shared layout.

The app bridges into the C core through `BudgetWarden-Bridging-Header.h`.

## C Core

The core library is written in C17 and provides:

- budget, category, and transaction models
- date and string helpers
- arena allocation utilities
- JSON parsing and serialization

JSON support is provided by the vendored `cJSON` dependency in `core/vendor/cJSON/`.

## License

This repository is source-available for educational, research, and reference purposes only. Building, running, using, redistributing, or commercially using the software requires a valid commercial license from Lazarov & Co EOOD.

See [LICENSE](LICENSE) for the full terms.
