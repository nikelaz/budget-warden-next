# Repository Guide

## Purpose

Budget Warden is a native budgeting app for macOS, iOS, Android, Linux, and Windows, with a standalone desktop Rust CLI. The portable data format is a local JSON-based `.budget` file.

## Map

| Path | Responsibility |
| --- | --- |
| `core/` | Rust shared domain: models, validation, codec, CRDT, reporting, money, templates, legacy migration, the MCP server (`src/mcp/`), and Google Drive cloud budgets (`src/cloud/`). |
| `core/boltffi.toml` | FFI-generation configuration. Apple output is `core/dist/apple`; Android output is `core/dist/android`. |
| `apple-core/` | `BWAppleCore` Swift package: Apple-facing helpers and re-export of generated `BWCore`. |
| `mac/` | SwiftUI macOS app. `ViewModels/BWStore.swift` owns budget mutations and file persistence. |
| `ios/` | SwiftUI iOS app. `ViewModels/BWStore.swift` owns document handling and budget mutations. |
| `android/` | Kotlin/Jetpack Compose app using generated Rust Kotlin/JNI bindings. `data/` owns Android document-provider I/O and recent-file preferences. |
| `cli/` | Standalone `budget-warden` Rust executable; owns command orchestration, JSON protocol, local file I/O, batching, and CLI settings while depending directly on `bw_core`. |
| `linux/` | GTK 4/libadwaita Linux desktop app; owns Linux UI, local preferences, recent budgets, and file selection while depending directly on `bw_core`. |
| `BudgetWarden.xcworkspace` | Combined Apple workspace; open this for macOS/iOS development. |

## Dependency Direction

```text
Rust core -> generated BWCore bindings -> BWAppleCore -> macOS / iOS apps
Rust core -> generated Android bindings -> Android platform I/O + Compose UI
Rust core -> bw_cli (`cli/`) -> command line and JSON protocol
Rust core -> Budget Warden Linux (`linux/`) -> GTK 4/libadwaita desktop app
```

Apple projects reference `../apple-core` as a local Swift package. `apple-core` references the generated package at `../core/dist/apple`.

## Change Routing

- Budget format, validation, reporting, money, templates, or migration: start in `core/src/`. Regenerate bindings when its exported FFI changes.
- MCP server protocol and tools: `core/src/mcp/`. Each app implements `BWMcpHost` for storage and shows the server in settings: `apple-core/src/BWMcpServerController.swift` (macOS/iOS), `android/.../data/McpServerController.kt`, `windows/ViewModels/AppViewModel.Mcp.cs`, and `linux/src/mcp.rs`.
- Google Drive sign-in, listing, sync, and sharing: `core/src/cloud/` (see `docs/cloud-sync.md`). Hosts supply HTTP and credential storage and show cloud budgets on their welcome screens: `apple-core/src/BWGoogleDriveController.swift` (macOS/iOS), `android/.../data/GoogleDriveController.kt`, `windows/ViewModels/AppViewModel.Cloud.cs`, `linux/src/cloud.rs`, and `cli/src/cloud.rs`. Test hosts against `bw_core::cloud::testing::FakeDrive` (feature `test-support`).
- iCloud Drive budgets (Apple only): `apple-core/src/BWICloudBudgetLibrary.swift`.
- Apple-only presentation/convenience behavior: `apple-core/src/`, then the relevant app under `mac/` or `ios/`.
- Apple app flows and persistence: begin in that app’s `ViewModels/BWStore.swift`; UI lives in `Views/`.
- Android UI: top-level Kotlin screen files and `ui/theme/`; document-provider I/O and recent-file persistence: `android/.../data/`; core behavior changes belong in `core/src/`.
- CLI commands, protocol, configuration, batching, and local persistence: `cli/`; budgeting rules continue to use the existing APIs in `core/src/`.
- Linux desktop UI, local preferences, and packaging metadata: `linux/`; budgeting rules and `.budget` compatibility continue to use `core/src/`.

## Generated and Local Files

- `core/dist/`, `core/target/`, and package `.build/` directories are generated and ignored. Do not hand-edit generated bindings.
- Build the CLI independently with `cargo build --manifest-path cli/Cargo.toml --release`; its direct dependency on `../core` does not require generated bindings.
- `cli/target/` is generated build output; keep the CLI lockfile committed.
- `linux/target/` is generated build output; keep the Linux app lockfile committed.
- `.swiftpm/`, `xcuserdata/`, `DerivedData/`, and IDE state are local-only and ignored.
- The previously tracked `apple-core/.swiftpm` scheme is intentionally removed from version control.

## Tests

- Rust: run Cargo tests from `core/` (`--features native-http -- --ignored` also reaches the real Drive API).
- CLI: run `cargo test --manifest-path cli/Cargo.toml` from the repository root.
- Swift package: run Swift tests from `apple-core/` after generated Apple bindings exist.
- Android: use the Gradle wrapper in `android/` for unit tests.

Keep format and behavior changes compatible with existing `.budget` files unless the migration code is updated alongside them.
