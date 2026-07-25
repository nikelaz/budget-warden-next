# Budget Warden for Windows

The Windows client is a native WinUI 3 application. Its UI follows the macOS app's budget, reporting, transaction, and settings flow while using Windows conventions such as `NavigationView`, command bars, content dialogs, and a selection inspector.

All budgeting behavior comes directly from the Rust crate in `../core`. BoltFFI generates a native `bw_core.dll` plus strongly typed C# records and functions; the WinUI project consumes that generated NuGet package. There is no parallel C# domain model or JSON bridge.

## Prerequisites

- Windows 10 version 1809 or later, with Developer Mode enabled
- .NET SDK 10
- Rust with the `x86_64-pc-windows-msvc` target
- Visual Studio 2026 (or Build Tools) with **Desktop development with C++**
- WinApp CLI
- Git

## Generate the C# bindings

From this directory:

```powershell
.\BuildCore.ps1
```

This checks out the BoltFFI revision pinned by `core/Cargo.toml` beneath the ignored `core/target` directory, applies the small C# generator compatibility patch in `patches/`, builds the native core, generates `core/dist/csharp`, and restores the WinUI project against the resulting local NuGet package.

Use `.\BuildCore.ps1 -Release` when producing a release native library.

## Build and run

```powershell
.\BuildAndRun.ps1
```

The script builds the x64 packaged app and launches it through WinApp CLI so package identity, file pickers, and app-local settings work correctly. Useful variants:

```powershell
.\BuildAndRun.ps1 -SkipRun
.\BuildAndRun.ps1 -Detach
.\BuildAndRun.ps1 -Configuration Release
```

## Tests

Run the cross-language core smoke test:

```powershell
dotnet run --project .\Tests\BudgetWarden.CoreSmoke\BudgetWarden.CoreSmoke.csproj
```

For the automated UI flow, launch detached, copy the returned process ID, and run:

```powershell
.\ui-tests.ps1 -AppPid 12345
```

The UI test creates an ignored `.budget` fixture, opens it through the Windows picker, exercises category and transaction mutations, checks navigation and persistence, audits interactive controls for automation IDs, and writes screenshots/results under `test-artifacts/`.
