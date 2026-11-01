# Budget Warden

Budget Warden is a source-available native macOS, iOS, Android, Linux, and Windows budgeting app with a standalone Rust command-line client. Budgets are stored as portable `.budget` files, locally or in iCloud Drive and Google Drive.

## Architecture

The repository has native clients around a shared budgeting domain:

```text
core/ (Rust domain and FFI)
  └── generated bindings in core/dist/ (not committed)
      └── apple-core/ (Swift convenience layer)
          ├── mac/ (SwiftUI macOS client)
          └── ios/ (SwiftUI iOS client)

windows/ (WinUI 3 client using generated C# bindings)

android/ (Compose client using generated Kotlin/JNI bindings)

cli/ (standalone Rust executable linking directly to bw_core)
linux/ (GTK 4/libadwaita desktop app linking directly to bw_core)
```

- `core/` is the canonical Rust implementation for models, validation, codec, CRDT, reporting, money, templates, and legacy migration. `boltffi.toml` configures Apple and Android binding generation.
- `apple-core/` wraps and re-exports the generated `BWCore` Swift package for the Apple apps.
- `mac/` and `ios/` are Xcode projects that consume `apple-core` as a local Swift package. Open `BudgetWarden.xcworkspace` for the combined Apple workspace.
- `android/` is a Gradle Android app using Jetpack Compose and the generated Rust core Kotlin/JNI bindings. Kotlin owns Android document-provider I/O, recent-file preferences, and Google Play services sign-in for Google Drive.
- `windows/` is a WinUI 3 app that consumes the generated Rust core directly through a local BoltFFI C# NuGet package. See `windows/README.md` for generation, build, and test commands.
- `cli/` contains the `budget-warden` executable. It links directly to `core/` through `bw_core`, owns command dispatch, JSON protocol, local file persistence, and CLI-only preferences, and builds independently from generated bindings.
- `linux/` contains the GTK 4/libadwaita desktop app. It links directly to `core/` through `bw_core`, owns Linux presentation and local preferences, and reads and writes the same `.budget` files without generated bindings. See [linux/README.md](linux/README.md) for Linux dependencies and build instructions.

## Cloud budgets

Budgets can live in Google Drive on every client and in iCloud Drive on macOS and iOS. Each app lists them next to local budgets on its welcome screen and can share a budget from the app: by email for Google Drive, and through the system share sheet's iCloud collaboration for iCloud Drive. Google Drive uses the non-sensitive `drive.file` scope, so a budget someone shared with you is added once by choosing it in the Google Picker (a static page in `picker/`, linked from the invitation email and from **Add Shared Budget…**).

- Google Drive is implemented once in `core/src/cloud/`. A cloud budget opens from a working copy that the app saves like any local file; sync CRDT-merges it with the newest Drive copy after every save and every minute, so edits from several people and devices converge. Hosts supply HTTP (`BWHttpClient`) and secure credential storage (`BWGoogleCredentialStore`).
- iCloud Drive budgets are files in the app's iCloud container, shown in iCloud Drive as "Budget Warden". `apple-core`'s `BWICloudBudgetLibrary` lists them, downloads them before opening, and merges conflicting iCloud versions with the CRDT.
- The CLI exposes Google Drive through `budget-warden cloud …` commands.

Google Drive needs OAuth clients and an API key in one Cloud project, the hosted picker page, and per-platform build settings; iCloud needs the iCloud Documents capability. See [docs/cloud-sync.md](docs/cloud-sync.md) for the design and the release checklist.

## MCP server

Every app can run a built-in [Model Context Protocol](https://modelcontextprotocol.io) server so AI assistants and other MCP clients can manage budgets the way the app does. Turn it on in the app's settings (Preferences on macOS and Linux, the Settings page on Windows, and a budget's Settings tab on iOS and Android), then give the client the URL shown there, for example `http://127.0.0.1:18765/<secret>/mcp`.

- The server speaks MCP over the Streamable HTTP transport and is implemented once in `core/src/mcp/`. Each app supplies storage through the `BWMcpHost` callback interface, so the server reaches only the app's open and recent budgets plus budgets it creates.
- Tools cover listing budgets and templates, creating and renaming budgets (from a template or a previous budget), reports, and creating, updating, moving, and deleting categories and transactions. Amounts are decimal strings such as `"12.50"`; dates use `YYYY-MM-DD`.
- Saves go through the same CRDT merge as the apps, and the app reloads a budget the server changed. New budgets go to a `Budgets` folder in the app's documents location (iCloud Drive on macOS when available, `Documents/Budget Warden` on Linux and Windows, app storage on Android).
- By default the server listens on this device only. "Allow other devices" listens on the local network and shows the LAN URL. The secret path segment is the only credential, so keep the URL private and use "Generate new URL" to revoke it. On mobile, the server runs only while the app is running.

Build the CLI from the repository root with `cargo build --manifest-path cli/Cargo.toml --release`. See [cli/README.md](cli/README.md) for commands, protocol schemas, persistence behavior, and distribution notes.

See [AGENTS.md](AGENTS.md) for a compact contributor map and change-routing notes.

## Requirements

- macOS and Xcode for the Apple clients
- Android Studio / a compatible JDK for Android development
- Windows, .NET 10, Visual Studio C++ build tools, and WinApp CLI for the Windows client
- Linux, GTK 4, libadwaita 1.5 or newer, pkg-config, and Rust/Cargo for the Linux client
- Rust and the project’s FFI generator when regenerating `core/dist` bindings
- Rust and Cargo for the standalone CLI

## License

This repository is source-available for educational, research, and reference purposes only. Building, running, using, redistributing, or commercially using the software requires a valid commercial license from Lazarov & Co EOOD.

See [LICENSE](LICENSE) for the full terms.
