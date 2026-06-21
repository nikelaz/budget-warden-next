# Repository Guidelines

## Project Structure

Budget Warden is a source-available native Apple budgeting app built with SwiftUI.

* `BudgetWarden.xcworkspace/` - shared Xcode workspace for local development
* `AppleCore/` - shared Swift package for core models, template loading, codecs, and common domain logic
* `BudgetWardenMac/` - macOS SwiftUI app, Xcode project, and UI tests
* `BudgetWardenIOS/` - iOS SwiftUI app and Xcode project
* `templates/` - budget templates stored in the repository; they are not consumed directly from this folder by the apps

## Coding Style

- Prefer readable, simple code over clever short tricks which are hard to understand
- Prefer focused changes that match the surrounding Swift style
- Keep shared budgeting/domain behavior in `AppleCore` when it is needed by more than one app
- Keep platform-specific file access, app lifecycle, and view behavior in the corresponding app target

## Verification

- Important: Do not run the macOS/iOS/Swift tests UNLESS explicitly asked. They are slow and expensive in terms of tokens.
- Prefer lightweight static checks and targeted file inspection unless the user asks for a build or test run.
- When available, use the Xcode MCP tools for Xcode builds, build logs, previews, documentation lookup, and project navigation instead of shelling out to `xcodebuild` or opening Xcode manually.
