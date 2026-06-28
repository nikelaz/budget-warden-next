# Repository Guidelines

## Project Structure

Budget Warden is a source-available native Apple budgeting app built with SwiftUI.

* `BudgetWarden.xcworkspace/` - shared Xcode workspace for local development
* `BudgetWardenAppleCore/` - shared Swift package for core models, template loading, codecs, and common domain logic
* `BudgetWardenMac/` - macOS SwiftUI app, Xcode project, and UI tests
* `BudgetWardenIOS/` - iOS SwiftUI app and Xcode project
* `templates/` - budget templates stored in the repository; they are not consumed directly from this folder by the apps

## Coding Style

- Prefer readable, simple code over clever short tricks which are hard to understand
- Prefer focused changes that match the surrounding Swift style
- Keep shared budgeting/domain behavior in `BudgetWardenAppleCore` when it is needed by more than one app
- Keep platform-specific file access, app lifecycle, and view behavior in the corresponding app target

## Architecture Layers

Keep the app layers minimal. Do not add extra abstraction layers unless the existing code clearly needs them.

- UI views render state, collect user intent, and present errors or success states.
- Stores own UI-facing state, initiate updates, call into the service layer, and translate service errors or successes back into UI state.
- `BudgetWardenAppleCore` owns the shared service layer, business logic, core models, codecs, template loading, and cross-platform helpers. Cross-platform helpers may contain business rules when they are useful to both apps.
- Platform targets (`BudgetWardenMac` and `BudgetWardenIOS`) own platform-specific file I/O, app lifecycle behavior, permissions, document handling, and view behavior.
- Service APIs in `BudgetWardenAppleCore` should express business operations. When they need file or platform behavior, depend on a narrow platform-provided boundary instead of moving file I/O into `BudgetWardenAppleCore`.

The usual flow should stay simple: `UI -> Store -> BudgetWardenAppleCore service/business logic -> platform file I/O boundary when needed -> service result/error -> Store -> UI`.

## Verification

- Important: Do not run the macOS/iOS/Swift tests UNLESS explicitly asked. They are slow and expensive in terms of tokens.
- Prefer lightweight static checks and targeted file inspection unless the user asks for a build or test run.
- For implementation validation, usually use the Xcode MCP tools to build, read build logs, and inspect build errors when available.
- When available, use the Xcode MCP tools for Xcode builds, build logs, previews, documentation lookup, and project navigation instead of shelling out to `xcodebuild` or opening Xcode manually.
