# Budget Warden CLI

`budget-warden` is a standalone Rust client for portable `.budget` files. It links directly to `bw_core`; it does not use generated FFI bindings or require a GUI runtime.

The CLI and native apps use the same budget model and core domain operations. CLI configuration and recent-file history are separate from the native apps' platform preferences.

## Machine output

Commands are noninteractive. JSON is the default and each completed command writes one response envelope to stdout. Diagnostics go to stderr. `--output text` prints a concise human view. Help and version are plain-text exceptions; use `budget-warden capabilities` for machine-readable feature and schema discovery.

```json
{
  "protocol_version": 1,
  "ok": true,
  "data": {},
  "error": null,
  "meta": {
    "command": "budget show",
    "budget_id": "…",
    "revision": 3,
    "revision_id": "…",
    "write_occurred": false,
    "migration_status": "current"
  }
}
```

For file-backed operations, metadata includes the budget identity and revision. Lists include that revision so a caller can detect that a later page came from a different snapshot. Money is encoded as a decimal string with scale two; report values such as `left_to_budget` retain their sign. Inputs also accept `--*-minor-units` integer strings, or in JSON an object such as `{"minor_units":"1234"}`. No floating-point amounts are accepted.

Exit status is `0` for success, `1` for an unexpected error, `2` for usage or input errors, `3` for a missing file or entity, `4` for decode/validation/domain failures, `5` for revision conflicts or lock timeouts, `6` for filesystem, permission, or network failures, and `7` when Google Drive needs the user to sign in. Error envelopes use stable codes; core error strings are retained as details and are not parsed to guess subtypes. Write errors report `commit_outcome` as `not_written`, `written`, or `unknown` when relevant.

Argument and JSON commands use the same core APIs. Structured requests reject unknown fields. UUIDs identify mutation targets; names are search filters and never choose an arbitrary entity.

## Common commands

Every command that reads or changes a budget takes an explicit `--file` path.

```sh
budget-warden capabilities
budget-warden budget create --file ./october.budget --title October --template basic-monthly
budget-warden template list
budget-warden template show vacation
budget-warden budget show --file ./october.budget
budget-warden category list --file ./october.budget --type expenses
budget-warden transaction create --file ./october.budget --category-id CATEGORY_UUID \
  --title Groceries --amount 42.50 --date 2026-10-10
budget-warden report summary --file ./october.budget
```

The alternative `transaction create --today` uses the host's local calendar date. Machine JSON requests must include an explicit valid `YYYY-MM-DD` date. Currency settings affect displayed preferences only; they never convert or change stored amounts.

`budget create --from PATH` creates a new budget with new budget and category IDs, carrying planned and accumulated amounts while clearing transactions. `budget copy --to PATH` creates a replica that retains the original budget ID and file contents. Use `--overwrite-budget-id UUID` to replace an existing destination after confirming its current budget ID. `budget delete` requires `--confirm-budget-id UUID`.

`budget migrate` requires either `--in-place` or `--to PATH`. In-place migration supports `--if-revision UUID`; a destination write is no-clobber unless its existing budget ID is supplied using `--overwrite-budget-id`. Validation and ordinary reads never rewrite or upgrade the source file.

Category types are `income`, `expenses`, `savings`, and `debt`. Category ordering is ordinal within type. Category list sorting and transaction list sorting are ascending, with UUID as the deterministic tie breaker. Text matching lowercases Unicode text without host-locale collation. Transaction `--after` and `--before` filters include their boundary dates. Pagination uses zero-based `--offset` and `--limit` (1 through 1000).

`template list` and `template show ID` read the same built-in catalog used by the native apps. Pass a stable catalog ID to `budget create --template ID`; use `template list` to discover available IDs and descriptions. New presets start with zero planned amounts. Weekly and biweekly labels do not filter reports by date, travel presets use the current income-allocation reports, and business presets are cash-planning categories rather than accounting profit.

Reports are derived only from `bw_core::reporting::build_reporting_summary`. The summary returns every total and all allocation, category, and comparison segments. `report allocation` and `report categories` accept `--mode planned|actual` filters.

Budget lifecycle and budget/category/transaction mutation commands accept `--dry-run`. They validate the request and show the proposed result without changing the budget file; preview IDs and revisions are provisional. `apply --dry-run` provides the same behavior for a batch.

## Batch requests

`apply` accepts one versioned request file or stdin. Operations execute in order against one in-memory budget and use one durable file commit. `$name` references can refer to IDs returned by earlier create operations in that request.

Requests are limited to 4 MiB and 1,000 operations.

```json
{
  "version": 1,
  "file": "./october.budget",
  "expected_revision_id": "REVISION_UUID",
  "operations": [
    {"op": "create_category", "local_ref": "food", "title": "Food", "category_type": "expenses", "planned_amount": "640.00"},
    {"op": "create_transaction", "category_id": "$food", "title": "Groceries", "date": "2026-10-10", "amount": {"minor_units": "4250"}}
  ]
}
```

```sh
budget-warden apply --input changes.json --dry-run
budget-warden apply --input changes.json --if-revision REVISION_UUID
cat changes.json | budget-warden apply --input -
```

The request schema is [protocol/v1.schema.json](protocol/v1.schema.json), the response envelope is [protocol/v1-envelope.schema.json](protocol/v1-envelope.schema.json), and common response data is described in [protocol/v1-output.schema.json](protocol/v1-output.schema.json). `capabilities` returns these versioned schemas. A failed operation identifies its zero-based index and leaves the budget file unwritten. Dry-run executes the same domain operations and validation; returned IDs and revision are provisional. Conditional writes check the revision before applying and again before commit. If a commit outcome is `unknown`, inspect the budget and revision before retrying a creation request.

## Google Drive

`cloud` commands keep budgets in Google Drive. Configure a Google OAuth "Desktop app" client with `BUDGET_WARDEN_GOOGLE_CLIENT_ID` and `BUDGET_WARDEN_GOOGLE_CLIENT_SECRET` (read at build time and overridable at run time), then sign in once in the browser:

```sh
budget-warden cloud sign-in            # opens the browser; --no-browser prints the URL
budget-warden cloud list               # your budgets and budgets shared with you
budget-warden cloud sync --id FILE_ID  # downloads or syncs; prints the working copy path
budget-warden transaction create --file WORKING_COPY ...
budget-warden cloud sync --file WORKING_COPY
budget-warden cloud upload --file ./october.budget
budget-warden cloud share --id FILE_ID --email ana@example.com --role writer
budget-warden cloud shares --id FILE_ID
budget-warden cloud unshare --id FILE_ID --share-id SHARE_ID
budget-warden cloud sign-out
```

Cloud budgets are edited through local working copies under `<config dir>/cloud`; `cloud sync` CRDT-merges a working copy with Google Drive in both directions. Credentials are stored in `<config dir>/google-credentials.json` with owner-only permissions. Exit status `7` (`sign_in_required`) means the user must run `cloud sign-in`; `cloud_not_configured` means the build has no client ID. `cloud list --offline` lists the last known budgets without network access. See [docs/cloud-sync.md](../docs/cloud-sync.md).

## Files and concurrency

Reads do not create CLI settings and can run with a read-only home directory. The device UUID is created lazily for commands that make CRDT changes, stored in the CLI config directory, and can be overridden with `--device-id UUID`. `--config-dir DIR` isolates CLI identity, currency, and recent-file settings for a harness. Platform defaults are `%APPDATA%/Budget Warden` on Windows, `~/Library/Application Support/Budget Warden` on macOS, and `$XDG_CONFIG_HOME/budget-warden` or `~/.config/budget-warden` on Linux.

CLI writers use a five-second exclusive lock on a persistent sibling named `<budget-path>.budget-warden.lock`; lock files stay in place so concurrent invocations keep locking the same file. The CLI rejects symbolic links as write targets and canonicalizes the containing directory. It stages writes beside the destination, syncs the staged file, atomically replaces or creates the destination, then syncs the directory where supported. New files use no-clobber creation. Moves copy and durably commit the destination before deleting the source; a response identifies when the destination was written but source deletion failed.

Locks coordinate CLI invocations only. GUI apps, external sync tools, network filesystems, and cloud providers do not join this lock protocol. The CLI rereads and merges through the core save API, but a final check/write race remains with uncooperative writers. Avoid editing the same budget simultaneously in a GUI and CLI when strict isolation matters. Apart from the `cloud` commands, the CLI only uses locally accessible paths; document providers, iCloud, OS bookmarks, and GUI recent-file preferences remain native-client features.

`recent` commands and `config` operate on CLI-owned settings and do not change native app preferences. `config set --currency USD` stores a display preference only. `budget list --directory PATH` discovers `.budget` files in one directory.

## Distribution

Build the CLI and GUI from the same `bw_core` commit. Keep dependency resolution in the separate CLI package; commit its generated lockfile and use `--locked` for reproducible release builds. Release packaging must include license terms, checksums, build metadata, installation instructions, native execution checks for each advertised operating system/architecture, and any required signing/notarization. Public or commercial redistribution must follow the repository [LICENSE](../LICENSE); the source-available license does not itself grant those rights.

The repository workflow can be dispatched manually to build and archive a standalone executable on native Linux, macOS, and Windows runners. Those workflow artifacts include this guide, protocol schemas, license terms, version/target metadata, the repository commit, and a SHA-256 checksum. Extract the archive, then place `budget-warden` on `PATH` (or `budget-warden.exe` in a Windows directory on `PATH`). The workflow artifacts are unsigned CI artifacts; they are not inserted into the GUI installers and do not perform Apple notarization or Windows package signing. The existing repository has no desktop release pipeline to extend for those steps.
