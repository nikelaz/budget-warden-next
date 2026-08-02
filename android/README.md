# Budget Warden for Android

The Android app uses the generated BoltFFI Kotlin bindings as its only budgeting domain implementation. Kotlin owns Android document-provider access, persisted URI permissions, recent-file preferences, and Compose presentation.

## Build

From PowerShell:

```powershell
cd android
.\BuildCore.ps1
$env:JAVA_HOME = 'C:\Program Files\Android\Android Studio\jbr'
.\gradlew.bat :app:assembleDebug
```

`BuildCore.ps1` builds the pinned BoltFFI CLI, compiles the Rust core for the four Android ABIs, and writes generated artifacts under `core/dist/android`. That directory is generated and intentionally ignored by Git.

After generation, Android Studio can sync and run the `app` configuration normally.

## Storage model

- Create uses Android's `CreateDocument` contract and writes a portable `.budget` file at the location chosen by the user.
- Open uses `OpenDocument` and retains the provider-granted URI permission when supported.
- Recent files are URI references only; the app has no browsable private vault, Room database, background sync, or Google Drive API integration.
- Each save reads and CRDT-merges the provider copy, atomically commits a private recovery snapshot, writes the provider URI, and re-reads it to reconcile a concurrently visible provider update. Recovery snapshots are safety copies, not the primary document store.
- Files placed in Drive, OneDrive, Dropbox, or another document provider are synchronized by that provider.
