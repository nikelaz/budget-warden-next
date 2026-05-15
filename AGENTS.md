# Repository Guidelines

## Project Structure

Budget Warden is a SwiftUI macOS budgeting app:

- `macos/` contains the SwiftUI macOS app, Xcode project, app UI, model, file I/O, and test targets.
- `macos-prototype` contains a vibe-coded prototype, ignore that project
- `templates/` contains starter `.budget` files.

## Development Commands

- Build the macOS app:

```sh
./macos/build.sh
```

- Run the macOS app:

```sh
./macos/run.sh
```

## Coding Style

- Prefer the simple, procedural solution to a problem, avoid introducing layers and OOP concepts.
- Keep budget-related data flow straightforward: load a `Budget`, mutate the Swift model, save the JSON file.
- Prefer readable, simple code over clever short tricks which are hard to understand.
- Always prioritize performance.
- Prefer focused changes that match the surrounding Swift style.

## Verification

- To verify app changes, run `macos/build.sh` and fix any build errors and warnings.
- Important: Do not run the macOS/Swift tests UNLESS explicitly asked. They are slow and expensive in terms of tokens.
