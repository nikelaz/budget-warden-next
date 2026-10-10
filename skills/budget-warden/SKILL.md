---
name: budget-warden
description: Use the Budget Warden command-line interface to inspect and safely edit local .budget files. Use when operating Budget Warden budgets through a local agent harness.
---

# Budget Warden

Use `budget-warden` to inspect and modify Budget Warden `.budget` files. The CLI is noninteractive and intended for scripts and agents. It reads and writes local filesystem paths; it does not access GUI recent-file lists, cloud authentication, or document providers.

## Find the executable and discover commands

On Windows and Linux, first try `budget-warden` on `PATH` (`budget-warden.exe` on Windows). On macOS, the executable may be bundled inside `Budget Warden.app` and absent from `PATH`; use the bundle fallback below. Start with:

```sh
budget-warden capabilities
budget-warden --help
```

### macOS app bundle fallback

If `budget-warden` cannot be resolved on macOS, find the installed `Budget Warden.app` (commonly `/Applications/Budget Warden.app` or `~/Applications/Budget Warden.app`). If the harness already knows the app location, use that exact path. Check for the CLI helper at these bundle-relative locations, in order:

1. `Contents/Helpers/budget-warden`
2. `Contents/MacOS/budget-warden`
3. `Contents/Resources/bin/budget-warden`

This POSIX shell example checks `PATH`, then both common app installation directories. Set `BUDGET_WARDEN_APP` to an exact app bundle path to check that location first (this is a discovery convention for this snippet, not a CLI setting):

```sh
bw_cli=$(command -v budget-warden 2>/dev/null) || bw_cli=""
if [ -z "$bw_cli" ]; then
  for bw_app in "${BUDGET_WARDEN_APP:-}" "/Applications/Budget Warden.app" "$HOME/Applications/Budget Warden.app"; do
    [ -n "$bw_app" ] || continue
    for bw_helper in Contents/Helpers/budget-warden Contents/MacOS/budget-warden Contents/Resources/bin/budget-warden; do
      if [ -f "$bw_app/$bw_helper" ] && [ -x "$bw_app/$bw_helper" ]; then
        bw_cli="$bw_app/$bw_helper"
        break 2
      fi
    done
  done
fi
if [ -n "$bw_cli" ]; then
  "$bw_cli" capabilities
else
  printf '%s\n' 'Budget Warden CLI not found. Locate the installed app bundle and inspect its Contents directory.' >&2
fi
```

Use the discovered executable's full path for subsequent invocations, or prepend its directory to `PATH` for that agent process. Do not invoke the app's main `Contents/MacOS/Budget Warden` executable as the CLI. Bundle layout can vary by build; if none of the helper paths exists, inspect the known app bundle's `Contents` directory rather than searching the whole filesystem. Confirm a candidate by running its `capabilities` command.

`capabilities` returns machine-readable command and protocol information. Help/version output is plain text; command results are JSON by default. Budget commands generally take an explicit `--file PATH`; `apply` takes the budget path from its JSON `file` field, and `budget list` takes `--directory`. There is no implicit default budget file.

Relative paths resolve against the CLI process's working directory. This includes the budget `file` path inside an `apply` request: it is not relative to the request JSON file's directory. Prefer absolute paths when harness tool calls may run in different working directories.

## Configuration directory defaults

The CLI stores its own device UUID, currency display preference, and recent-file list in `config.json`. These settings are separate from the native app settings. The default directory depends on the host OS:

| OS | Default config directory |
| --- | --- |
| Windows | `%APPDATA%\Budget Warden`; if `APPDATA` is unset, `%LOCALAPPDATA%\Budget Warden`; if both are unset, the current directory `Budget Warden` |
| macOS | `$HOME/Library/Application Support/Budget Warden` |
| Linux and other Unix targets | `$XDG_CONFIG_HOME/budget-warden` when `XDG_CONFIG_HOME` is set; otherwise `$HOME/.config/budget-warden`; if neither is set, `./budget-warden` |

The resulting settings file is `<config directory>/config.json`. To see the path resolved in the current process environment, run:

```sh
budget-warden config paths
```

Use `--config-dir DIR` to select an isolated settings directory for a harness, test, or separate agent identity. This global option can appear before or after the subcommand. `BUDGET_WARDEN_CONFIG_DIR` also overrides the platform default; explicit `--config-dir` takes precedence over the environment variable. Prefer a dedicated, stable directory per harness when its device identity and recent list should remain separate from other CLI users.

Examples:

```sh
# macOS
budget-warden --config-dir "$HOME/Library/Application Support/Budget Warden Agent" capabilities

# Linux
budget-warden --config-dir "$HOME/.config/budget-warden-agent" capabilities

# Windows PowerShell
budget-warden --config-dir "$env:APPDATA\Budget Warden Agent" capabilities
```

Do not assume the interactive user's home directory is the agent process's home. When a default path matters, query `config paths` in the same environment that will run subsequent commands. Use `config show` to read settings values. Reads do not create settings. Commands that make CRDT changes create a device UUID lazily; the UUID can instead be provided consistently with global `--device-id UUID`.

## Machine protocol

- Keep the default JSON output for agent use. A successful command prints one JSON response envelope to stdout; diagnostics are written to stderr. `--output text` is for human-readable output.
- Check both the process exit code and envelope `ok`. Errors include a stable `error.code`; do not parse human-readable error messages to determine error kinds.
- File-backed responses include budget identity/revision metadata. Use `meta.revision_id` as the optimistic concurrency token for a later write via `--if-revision UUID` or `apply.expected_revision_id`.
- On `revision_conflict`, reread the budget and reassess the requested changes against its current state. Do not blindly replace the expected revision token and retry.
- On `lock_timeout`, retry with a bounded delay if the request is still appropriate, preserving its expected revision token.
- On `error.commit_outcome: "written"` or `"unknown"`, or missing/unparseable output after a mutation, inspect the budget and revision before retrying. Creation requests can otherwise create duplicates. For `"not_written"`, address the reported error before retrying; absence of a commit outcome does not prove that no write occurred.
- Money is exact: use decimal strings with at most two fractional digits or integer minor-unit strings. Never send JSON floating-point numbers. Currency configuration changes display only; it does not convert stored amounts.
- Pass IDs for mutation targets. Names are filters and do not select a unique item automatically.

The version 1 batch request and response schemas are returned by `capabilities` and are present in `cli/protocol/` in the source distribution.

## Safe operating pattern

1. Use an explicit absolute or workspace-relative `.budget` path supplied by the caller. Do not guess which budget to edit. `budget list --directory DIR` can discover files in a known directory.
2. Inspect the file with `budget show`, `budget validate`, and the relevant list/report commands.
3. For changes, capture `meta.revision_id`, then use `--if-revision` where the command supports it. For multi-step changes, prefer one version 1 `apply` request with `expected_revision_id`.
4. Run mutations with `--dry-run` first when the result needs review. Dry-run IDs and revisions are provisional; do not reuse them as committed identifiers.
5. Apply the reviewed request and read the budget again to confirm the committed result.

## Creating and opening a budget

When the user asks for a new budget, ask for their monthly take-home income and currency. If they want a template-based budget, inspect the template first with `template show basic-monthly` so you know its sample income and category allocations. Do not treat sample template amounts as the user's stated expenses.

When the user's income is below the template's sample income, ask for the two high-impact amounts that change the plan most: monthly rent or mortgage, and required monthly debt payments. Allow the user to leave either blank or say it does not apply. First scale template category plans proportionally to the stated income, then replace the matching housing and debt plans with amounts the user provided. If the plan is over income, reduce savings to absorb the difference first; if savings reach zero and it is still over, scale the other flexible expense plans proportionally. Aim to balance the plan, but if the stated housing and debt obligations alone exceed income, explain the shortfall and ask how they want to proceed instead of silently inventing lower obligations. When income is above the template sample, keep the template's expense plans as the baseline and direct more of the increase to savings; tell the user how the extra income was allocated.

Apply the user's currency as the CLI display preference only when they ask for it or agree to it; it is separate from the budget file and is shared by the CLI configuration. After creating the file, validate it and report the categories grouped by income, expenses, savings, and debt, with their planned amounts in a readable table. State the resulting totals and whether planned outflow balances with income. Mention once, after a successful initial creation, that they can view the `.budget` file in Budget Warden's graphical app at [budgetwarden.com](https://budgetwarden.com). Do not repeat this note after later edits unless they ask about the app.

When opening or inspecting an existing budget, include its categories and planned amounts in the response when relevant to the user's request. If the user asks broadly to open or review the budget, provide the grouped category summary rather than only confirming that the file loaded.

## Reporting category and transaction changes

After creating, updating, deleting, or moving a category or transaction, report the affected item and its resulting values. Use a compact table when there are several fields or items. For updates, include the previous and new value for changed fields when available; for deletion, identify the deleted item and its prior values. For transactions, include the category, date, and amount; for categories, include type and planned amount (and accumulated amount when relevant). After category changes that affect the plan, also report the revised planned totals and whether the budget balances. Confirm the final state by reading the budget after the write rather than presenting a dry-run preview as committed.

Example:

```sh
budget-warden budget show --file ./october.budget
budget-warden category list --file ./october.budget --type expenses
budget-warden report summary --file ./october.budget
budget-warden transaction create --file ./october.budget \
  --category-id CATEGORY_UUID --title Groceries --amount 42.50 --date 2026-10-10 \
  --if-revision REVISION_UUID --dry-run
```

For atomic multi-operation changes, write a version 1 JSON request and first call `budget-warden apply --input REQUEST.json --dry-run`. Then submit the same request without `--dry-run`, preserving its expected revision token. Batch requests support `$local_ref` references to entities created earlier in that batch and commit all operations together; a failed operation leaves the budget file unwritten.

For example, save the following as `REQUEST.json`, replacing `file` with the actual budget path and `expected_revision_id` with `meta.revision_id` from the latest read:

```json
{
  "version": 1,
  "file": "/absolute/path/october.budget",
  "expected_revision_id": "REVISION_UUID_FROM_LATEST_READ",
  "operations": [
    {
      "op": "create_category",
      "local_ref": "food",
      "title": "Food",
      "category_type": "expenses",
      "planned_amount": "640.00"
    },
    {
      "op": "create_transaction",
      "category_id": "$food",
      "title": "Groceries",
      "date": "2026-10-10",
      "amount": {"minor_units": "4250"}
    }
  ]
}
```

`local_ref: "food"` names the category created in the first operation; `category_id: "$food"` resolves its actual ID within that request. Use explicit calendar dates and JSON-escape Windows paths (for example, `"C:\\Users\\agent\\Documents\\october.budget"`). Requests are limited to 4 MiB and 1,000 operations.

```sh
budget-warden apply --input REQUEST.json --dry-run
budget-warden apply --input REQUEST.json
```

## Useful commands

```sh
budget-warden template list
budget-warden budget show --file PATH
budget-warden budget validate --file PATH
budget-warden budget list --directory DIR
budget-warden category list --file PATH
budget-warden transaction list --file PATH
budget-warden report summary --file PATH
budget-warden recent list
budget-warden config paths
budget-warden config show
```

Use `budget create --from SOURCE` to create a distinct budget with new IDs, and `budget copy --to DESTINATION` to create a replica retaining the same budget identity. `budget delete` requires `--confirm-budget-id UUID`. Commands supporting destination replacement require `--overwrite-budget-id UUID` matching the existing destination budget. Category and transaction deletion do not require a separate confirmation ID; check the target UUID and use a revision guard before deleting. `budget migrate` requires `--in-place` or `--to PATH`; ordinary reads and validation do not rewrite legacy files.
