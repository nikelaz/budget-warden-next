# Budget Warden for Linux

The Linux desktop app is a native GTK 4 and libadwaita client. It uses the shared
Rust core directly and reads and writes the same portable `.budget` files as the
macOS, iOS, Android, Windows, and CLI clients.

## Build and run

Install Rust, Cargo, GTK 4 development files, libadwaita development files, and
pkg-config. Building also uses `glib-compile-resources` to embed the application
icon (provided by GLib development tools). On Debian and Ubuntu:

```sh
sudo apt install build-essential pkg-config libgtk-4-dev libadwaita-1-dev libglib2.0-dev-bin
cargo run --manifest-path linux/Cargo.toml
```

On Arch Linux:

```sh
sudo pacman -S base-devel pkgconf gtk4 libadwaita glib2
cargo run --manifest-path linux/Cargo.toml
```

Build an optimized executable with:

```sh
cargo build --release --manifest-path linux/Cargo.toml
```

The app requires GTK 4.10 or newer and libadwaita 1.5 or newer. `data/` contains the
freedesktop desktop entry, AppStream metadata, MIME definition, and application
icon for Linux packaging. The desktop entry registers the app as a handler for
`.budget` files. The executable embeds its icon for in-app use, including
when launched with `cargo run`.

## Included workflows

- Welcome screen with recent budgets and open/create actions
- Core catalog templates and previous-budget reuse
- Budget category groups, planned/actual totals, accumulated balances, category
  ordering, editing, deletion, and per-category transaction windows
- Reporting overview cards, stacked income/allocation bars, and planned/actual
  doughnut breakdowns with amount and percentage legends
- Search, date and amount filters, sorting, editing, moving, and deleting
  transactions
- Currency preference, recent budgets, keyboard shortcuts, and schema migration
- Google Drive budgets on the welcome screen, with sign-in in the browser, sync
  after every save and every minute, creating or copying budgets to Drive,
  sharing by email, and adding budgets shared with you through the Google
  Picker (see
  [docs/cloud-sync.md](../docs/cloud-sync.md))

Google Drive needs a Google OAuth "Desktop app" client. Set
`BUDGET_WARDEN_GOOGLE_CLIENT_ID` and `BUDGET_WARDEN_GOOGLE_CLIENT_SECRET` when
building (they can also be overridden at run time); without them the app hides
Google Drive. `BUDGET_WARDEN_GOOGLE_PICKER_URL` points at the hosted picker page
(`picker/`) used by **Add Shared Budget…**.

The app stores its device ID, currency choice, and recent file list under
`$XDG_CONFIG_HOME/budget-warden` (or `~/.config/budget-warden`). Budget data
remains in the selected `.budget` files. The Google sign-in is kept in
`google-credentials.json` there with owner-only permissions, and working copies
of Google Drive budgets in `cloud/`.
