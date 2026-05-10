# Repository Guidelines

## Project Structure

Budget Warden is a macOS budgeting app with a small C core:

- `core/` contains the C17 budgeting engine, JSON serialization, and core tests.
- `core/vendor/cJSON/` is vendored third-party code. Avoid editing it unless the task is specifically about that dependency.
- `macos/` contains the SwiftUI macOS app, Xcode project and app UI and unit tests projects.
- `templates/` contains starter `.budget` files.

## Development Commands

- C Core Tests

```sh
./core/test.sh
```

- Use the XCode MCP to build, run and test the macOS app (if available), otherwise a build and run scripts are available:

```sh
./macos/build.sh
./macos/run.sh
```

## Coding Style

- Prefer the simple, procedural solution to a problem, avoid introducing layers and OOP concepts
- Keep all business logic and budget-related logic in the C core for reusability in other future GUI apps, besides the macOS app
- The macOS app should primarily contain the UI layer and the OS File I/O layer - the layers that require OS APIs
- Prefer readable, simple code over clever short tricks which are hard to understand
- Always prioritize performance
- Prefer focused changes that match the surrounding C or Swift style.

## Verification

- To verify C changes, run `core/test.sh`.
- To verify the macOS app changes run `macos/build.sh` and fix any build errors and warnings.
- Important: Do not run the macOS/Swift tests UNLESS I explicitly ask you to. They are slow and expensive in terms of tokens.
- If I ask you to run the macOS unit/UI tests you can use the XCode MCP to run them (if the MCP is available)
