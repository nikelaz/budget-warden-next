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

The executable under `bin\...\AppX` is package payload and must not be
launched directly. In Visual Studio, use the `BudgetWarden.Windows` MSIX
profile; from a terminal, use `BuildAndRun.ps1`. Direct execution has no
package identity and causes Windows App SDK activation to fail with
`REGDB_E_CLASSNOTREG`.

## Publish and run a Release NativeAOT build

`Release` publishing enables .NET NativeAOT for this project. Publish the x64
application to an ignored artifacts directory:

```powershell
dotnet publish .\BudgetWarden.Windows.csproj `
  -c Release `
  -r win-x64 `
  -p:Platform=x64 `
  -p:GenerateAppxPackageOnBuild=false `
  -p:AppxPackageSigningEnabled=false `
  -p:PublishDir=artifacts\aot\
```

Launch the published payload through WinApp CLI so it receives package
identity:

```powershell
winapp run .\artifacts\aot `
  --manifest .\Package.appxmanifest `
  --output-appx-directory .\artifacts\aot-layout `
  --debug-output
```

Use `--detach` instead of `--debug-output` to launch without attaching the
crash debugger. Do not run `artifacts\aot\BudgetWarden.Windows.exe` directly.

## Create, sign, and install an MSIX

The following workflow creates an x64 Release NativeAOT package for local
sideloading. First create the unsigned MSIX:

```powershell
dotnet publish .\BudgetWarden.Windows.csproj `
  -c Release `
  -r win-x64 `
  -p:Platform=x64 `
  -p:GenerateAppxPackageOnBuild=true `
  -p:AppxPackageSigningEnabled=false `
  -p:AppxBundle=Never `
  -p:UapAppxPackageBuildMode=SideloadOnly `
  -p:AppxPackageDir=artifacts\packages\
```

Generate a development certificate whose publisher matches
`Package.appxmanifest`:

```powershell
winapp cert generate `
  --manifest .\Package.appxmanifest `
  --output .\artifacts\devcert.pfx `
  --if-exists skip
```

Trust that certificate once on the development machine. Run this command from
an Administrator PowerShell:

```powershell
winapp cert install .\artifacts\devcert.pfx
```

Sign the newest generated package and install it:

```powershell
$package = Get-ChildItem .\artifacts\packages -Recurse -Filter *.msix |
  Sort-Object LastWriteTime -Descending |
  Select-Object -First 1

winapp sign $package.FullName .\artifacts\devcert.pfx
Add-AppxPackage $package.FullName
```

Launch **Budget Warden** from the Start menu after installation. The generated
certificate uses the WinApp CLI development password (`password`) and is for
local testing only. Do not distribute it as a production signing identity.
For external sideloading, sign with a trusted code-signing certificate and a
timestamp server; Microsoft Store submissions use the publisher identity
assigned in Partner Center.

To inspect the compressed package size:

```powershell
$package | Select-Object FullName, @{
  Name = "SizeMiB"
  Expression = { [math]::Round($_.Length / 1MB, 2) }
}
```
