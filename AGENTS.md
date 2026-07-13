# Repository Guidelines

## Project Structure

Budget Warden is a source-available budgeting app with native Apple clients built with SwiftUI and a native Android client built with Kotlin and Jetpack Compose.

* `BudgetWarden.xcworkspace/` - shared Xcode workspace for local development
* `BudgetWardenAppleCore/` - shared Swift package for core models, template loading, codecs, and common domain logic
* `BudgetWardenMac/` - macOS SwiftUI app, Xcode project, and UI tests
* `BudgetWardenIOS/` - iOS SwiftUI app and Xcode project
* `BudgetWardenAndroid/` - standalone Android Gradle project and Jetpack Compose app
* `templates/` - budget templates stored in the repository; they are not consumed directly from this folder by the apps

## Android App

`BudgetWardenAndroid/` is a single-module Android application. Open this directory, not the repository root, as the project in Android Studio.

- Application module: `BudgetWardenAndroid/app/`
- Application ID and namespace: `com.lazarovco.budgetwarden`
- Entry point and current Compose screens/dialogs: `app/src/main/java/com/lazarovco/budgetwarden/MainActivity.kt`
- Android persistence and `.budget` import/export: `app/src/main/java/com/lazarovco/budgetwarden/data/BudgetRepository.kt`
- Android domain models and budgeting calculations: `app/src/main/java/com/lazarovco/budgetwarden/domain/BudgetModels.kt`
- Material theme: `app/src/main/java/com/lazarovco/budgetwarden/ui/theme/`
- Resources, strings, and vector icons: `app/src/main/res/`
- Version catalog: `gradle/libs.versions.toml`
- Minimum SDK 24; compile/target SDK 37; JDK 17 or newer is required for the Android build toolchain.

The Android app is currently standalone and does not depend on `BudgetWardenAppleCore`. Keep Android business behavior compatible with the Apple implementations and the `.budget` file format when changing duplicated domain or codec behavior.

### Build and Run Android

Run Gradle commands from `BudgetWardenAndroid/`. On Windows PowerShell:

```powershell
cd BudgetWardenAndroid
.\gradlew.bat :app:assembleDebug
```

The debug APK is written beneath `app/build/outputs/apk/debug/`. To install it on a running Android emulator or connected device:

```powershell
.\gradlew.bat :app:installDebug
```

Alternatively, open `BudgetWardenAndroid/` in Android Studio, allow Gradle sync to finish, select the `app` run configuration and an API 24+ emulator/device, then click Run. SDK 37 must be installed. `local.properties` is machine-specific and should point `sdk.dir` at the local Android SDK; do not commit machine-local changes to it.

Useful explicit verification commands are:

```powershell
.\gradlew.bat :app:compileDebugKotlin
.\gradlew.bat :app:testDebugUnitTest
.\gradlew.bat :app:connectedDebugAndroidTest
```

The connected test command requires a running emulator or attached device.

## Coding Style

- Prefer readable, simple code over clever short tricks which are hard to understand
- Prefer focused changes that match the surrounding Swift style
- For Android, prefer idiomatic Kotlin, Jetpack Compose, and Material 3 components; keep user-visible text in `res/values/strings.xml` and interactive icons accessible.
- Keep shared budgeting/domain behavior in `BudgetWardenAppleCore` when it is needed by more than one app
- Keep platform-specific file access, app lifecycle, and view behavior in the corresponding app target

## Architecture Layers

Keep the app layers minimal. Do not add extra abstraction layers unless the existing code clearly needs them.

- UI views render state, collect user intent, and present errors or success states.
- Stores own UI-facing state, initiate updates, call into the service layer, and translate service errors or successes back into UI state.
- `BudgetWardenAppleCore` owns the shared service layer, business logic, core models, codecs, template loading, and cross-platform helpers. Cross-platform helpers may contain business rules when they are useful to both apps.
- Platform targets (`BudgetWardenMac`, `BudgetWardenIOS`, and `BudgetWardenAndroid`) own platform-specific file I/O, app lifecycle behavior, permissions, document handling, and view behavior.
- Service APIs in `BudgetWardenAppleCore` should express business operations. When they need file or platform behavior, depend on a narrow platform-provided boundary instead of moving file I/O into `BudgetWardenAppleCore`.

The usual Apple flow should stay simple: `UI -> Store -> BudgetWardenAppleCore service/business logic -> platform file I/O boundary when needed -> service result/error -> Store -> UI`.

The current Android flow is `Compose UI -> app state/actions in MainActivity -> Android domain/repository -> local file I/O -> updated Compose state`. Keep changes focused within that structure unless the code clearly warrants extracting a store or service.

## Verification

- Important: Do not run macOS/iOS/Swift or Android builds/tests UNLESS explicitly asked. They are slow and expensive in terms of tokens.
- Prefer lightweight static checks and targeted file inspection unless the user asks for a build or test run.
- For implementation validation, usually use the Xcode MCP tools to build, read build logs, and inspect build errors when available.
- When available, use the Xcode MCP tools for Xcode builds, build logs, previews, documentation lookup, and project navigation instead of shelling out to `xcodebuild` or opening Xcode manually.
