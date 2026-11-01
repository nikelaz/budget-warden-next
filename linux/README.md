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

## Release bundles

From the repository root, build both downloadable formats:

```sh
./scripts/linux/release.sh
```

Use `./scripts/linux/release.sh flatpak` or `./scripts/linux/release.sh appimage`
to build one format. Outputs go to `linux/dist/` (override with `OUTPUT_DIR`):

- `Budget-Warden-VERSION-ARCH.flatpak`
- `Budget-Warden-VERSION-ARCH.AppImage`
- `SHA256SUMS-all` (or `SHA256SUMS-flatpak` / `SHA256SUMS-appimage`)

Versions come from `linux/Cargo.toml`. Run on each native architecture (`x86_64`
or `aarch64`) to publish both architectures. Builds use the committed lockfile
and include the current working tree's source. Python 3.11+ and Rust/Cargo are
required. The script uses temporary build directories and does not publish or
sign artifacts.

To include Google Drive, put the desktop OAuth credentials in the ignored
`.linux-release-secrets.env` file at the repository root:

```sh
BUDGET_WARDEN_GOOGLE_CLIENT_ID='your-desktop-client-id'
BUDGET_WARDEN_GOOGLE_CLIENT_SECRET='your-desktop-client-secret'
BUDGET_WARDEN_GOOGLE_PICKER_URL='https://your-hosted-picker/'
```

The release script exports these settings for both AppImage and Flatpak builds.
The picker URL is optional for sign-in and sync; it enables adding shared budgets.
The desktop OAuth credentials are embedded in the executable, as expected for
an installed-app OAuth client. Keep other deployment keys out of this file.

### Flatpak

Install Flatpak and flatpak-builder, then prepare the build runtime once:

```sh
flatpak remote-add --user --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
flatpak install --user flathub org.gnome.Platform//49 org.gnome.Sdk//49 org.freedesktop.Sdk.Extension.rust-stable//25.08
./scripts/linux/release.sh flatpak
```

The script stages the app and Rust core, vendors locked Cargo dependencies
from both lockfiles (including Git dependencies), and compiles offline inside the GNOME SDK.
Both lockfiles are needed because BoltFFI macros inspect the core package independently. Network
access is needed during dependency preparation. The manifest in `packaging/`
uses a staged `source/` directory prepared by the release script; run the script
rather than invoking flatpak-builder on that manifest directly.

The sandbox allows graphics and networking for Google Drive, OAuth's loopback
callback, and the MCP server. Budget files are accessed through the file chooser
portal. Settings and credentials are stored in Flatpak's private app directory.
Desktop, icon, MIME, and AppStream integration is installed by Flatpak.

Users install the download with:

```sh
flatpak install --user ./Budget-Warden-VERSION-ARCH.flatpak
flatpak run com.lazarovco.BudgetWarden
```

Flathub must be configured to supply the GNOME runtime. This creates a standalone
bundle; publishing to Flathub is a separate process.

### AppImage

Install the native build dependencies above, plus `patchelf`, `file`, `librsvg2-bin`
(provides `rsvg-convert` to generate the required 256×256 PNG AppImage icon), and the
tools required by linuxdeploy's GTK plugin (including GLib schema and
GdkPixbuf tools). Obtain [linuxdeploy](https://github.com/linuxdeploy/linuxdeploy)
for the build architecture and the current
[GTK plugin](https://github.com/linuxdeploy/linuxdeploy-plugin-gtk), which supports
GTK 4. Put executable `linuxdeploy` and `linuxdeploy-plugin-gtk.sh` on `PATH`,
or set `LINUXDEPLOY` to the linuxdeploy executable's path. Keep known versions
of these tools in your release environment for reproducible packaging.

```sh
./scripts/linux/release.sh appimage
chmod +x linux/dist/Budget-Warden-*.AppImage
```

linuxdeploy bundles shared libraries and the GTK plugin supplies GTK resources,
schemas, and loaders.
The release script removes the GTK plugin's forced theme and X11 overrides before
export so libadwaita can apply its native styling and GTK can select Wayland or X11.
Build on the oldest supported Linux distribution with
GTK >= 4.10 and libadwaita >= 1.5 (for example, Ubuntu 24.04); AppImages still
depend on the host's glibc and graphics stack. Users can run the AppImage directly;
launcher integration can be provided by their AppImage manager. It includes the
desktop entry and icon but does not install them into the host automatically.

Before publishing, smoke-test each architecture on clean target systems: launch,
open/save and reopen a `.budget` file, file association, Google Drive browser
sign-in, and MCP access. Test both Wayland and X11 and confirm AppImage startup
on the oldest supported distribution. Packaging success alone does not verify
runtime compatibility.

## Included workflows

- Welcome screen with recent budgets and open/create actions
- Core catalog templates and previous-budget reuse
- Budget category groups, planned/actual totals, accumulated balances,
  drag-and-drop category ordering (Alt+Up/Alt+Down from the keyboard), editing,
  deletion, and per-category transaction windows
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

Each budget stores its own currency, chosen under **Preferences**. The app
stores its device ID, default currency (for new budgets and budgets from
earlier versions), and recent file list under
`$XDG_CONFIG_HOME/budget-warden` (or `~/.config/budget-warden`). Budget data
remains in the selected `.budget` files. The Google sign-in is kept in
`google-credentials.json` there with owner-only permissions, and working copies
of Google Drive budgets in `cloud/`.
