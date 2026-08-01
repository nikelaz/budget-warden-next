# Budget Warden

Budget Warden is a source-available native macOS, iOS, Android, and Windows budgeting app. Budgets are stored as portable local `.budget` files.

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
```

- `core/` is the canonical Rust implementation for models, validation, codec, CRDT, reporting, money, templates, and legacy migration. `boltffi.toml` configures Apple and Android binding generation.
- `apple-core/` wraps and re-exports the generated `BWCore` Swift package for the Apple apps.
- `mac/` and `ios/` are Xcode projects that consume `apple-core` as a local Swift package. Open `BudgetWarden.xcworkspace` for the combined Apple workspace.
- `android/` is a Gradle Android app using Jetpack Compose and the generated Rust core Kotlin/JNI bindings. Kotlin owns Android document-provider I/O and recent-file preferences; there is no app-managed cloud synchronization.
- `windows/` is a WinUI 3 app that consumes the generated Rust core directly through a local BoltFFI C# NuGet package. See `windows/README.md` for generation, build, and test commands.

See [AGENTS.md](AGENTS.md) for a compact contributor map and change-routing notes.

## Requirements

- macOS and Xcode for the Apple clients
- Android Studio / a compatible JDK for Android development
- Windows, .NET 10, Visual Studio C++ build tools, and WinApp CLI for the Windows client
- Rust and the project’s FFI generator when regenerating `core/dist` bindings

## License

This repository is source-available for educational, research, and reference purposes only. Building, running, using, redistributing, or commercially using the software requires a valid commercial license from Lazarov & Co EOOD.

See [LICENSE](LICENSE) for the full terms.
