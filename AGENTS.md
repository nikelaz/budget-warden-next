# Repository Guide

## Purpose

Budget Warden is a native budgeting app for macOS, iOS, and Android. The portable data format is a local JSON-based `.budget` file.

## Map

| Path | Responsibility |
| --- | --- |
| `core/` | Rust shared domain: models, validation, codec, CRDT, reporting, money, templates, and legacy migration. |
| `core/boltffi.toml` | FFI-generation configuration. Apple output is `core/dist/apple`; Android output is `core/dist/android`. |
| `apple-core/` | `BWAppleCore` Swift package: Apple-facing helpers and re-export of generated `BWCore`. |
| `mac/` | SwiftUI macOS app. `ViewModels/BWStore.swift` owns budget mutations and file persistence. |
| `ios/` | SwiftUI iOS app. `ViewModels/BWStore.swift` owns document handling and budget mutations. |
| `android/` | Kotlin/Jetpack Compose app. `data/` contains file, Room, and Drive sync code; `domain/` contains Android models, CRDT/rebase, and reporting. |
| `BudgetWarden.xcworkspace` | Combined Apple workspace; open this for macOS/iOS development. |

## Dependency Direction

```text
Rust core -> generated BWCore bindings -> BWAppleCore -> macOS / iOS apps
Android app -> Android domain + data + Compose UI
```

Apple projects reference `../apple-core` as a local Swift package. `apple-core` references the generated package at `../core/dist/apple`.

## Change Routing

- Budget format, validation, reporting, money, templates, or migration: start in `core/src/`. Regenerate bindings when its exported FFI changes.
- Apple-only presentation/convenience behavior: `apple-core/src/`, then the relevant app under `mac/` or `ios/`.
- Apple app flows and persistence: begin in that app’s `ViewModels/BWStore.swift`; UI lives in `Views/`.
- Android UI: top-level Kotlin screen files and `ui/theme/`; persistence/sync: `android/.../data/`; Android domain logic: `android/.../domain/`.

## Generated and Local Files

- `core/dist/`, `core/target/`, and package `.build/` directories are generated and ignored. Do not hand-edit generated bindings.
- `.swiftpm/`, `xcuserdata/`, `DerivedData/`, and IDE state are local-only and ignored.
- The previously tracked `apple-core/.swiftpm` scheme is intentionally removed from version control.

## Tests

- Rust: run Cargo tests from `core/`.
- Swift package: run Swift tests from `apple-core/` after generated Apple bindings exist.
- Android: use the Gradle wrapper in `android/` for unit tests.

Keep format and behavior changes compatible with existing `.budget` files unless the migration code is updated alongside them.
