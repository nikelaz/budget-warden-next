#!/usr/bin/env bash
# Build downloadable Linux bundles on a native Linux build host.
set -euo pipefail

usage() {
    echo "Usage: $0 [all|flatpak|appimage]"
    echo "Output: linux/dist/ (override with OUTPUT_DIR)"
    echo "AppImage tools: LINUXDEPLOY and linuxdeploy-plugin-gtk.sh on PATH"
}
format=${1:-all}
case "$format" in
    -h|--help) usage; exit 0 ;;
    all|flatpak|appimage) ;;
    *) usage >&2; exit 2 ;;
esac
[[ $# -le 1 ]] || { usage >&2; exit 2; }
[[ $(uname -s) == Linux ]] || { echo 'A Linux build host is required.' >&2; exit 1; }
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$root"
# Local release configuration is intentionally excluded from version control.
if [[ -f "$root/.linux-release-secrets.env" ]]; then
    set -a
    source "$root/.linux-release-secrets.env"
    set +a
fi
if [[ -z ${BUDGET_WARDEN_GOOGLE_CLIENT_ID:-} || -z ${BUDGET_WARDEN_GOOGLE_CLIENT_SECRET:-} ]]; then
    echo 'Warning: Google Drive will be hidden; configure the desktop OAuth client in .linux-release-secrets.env.' >&2
fi
need() { command -v "$1" >/dev/null || { echo "Missing required tool: $1" >&2; exit 1; }; }
for tool in cargo python3 install sha256sum; do need "$tool"; done
if [[ $format == all || $format == flatpak ]]; then
    need flatpak
    need flatpak-builder
fi
if [[ $format == all || $format == appimage ]]; then
    LINUXDEPLOY=${LINUXDEPLOY:-linuxdeploy}
    need "$LINUXDEPLOY"
    LINUXDEPLOY=$(realpath "$(command -v "$LINUXDEPLOY")")
    need linuxdeploy-plugin-gtk.sh
    need pkg-config
    need rsvg-convert
    pkg-config --atleast-version=4.10 gtk4
    pkg-config --atleast-version=1.5 libadwaita-1
fi
version=$(python3 -c 'import tomllib; print(tomllib.load(open("linux/Cargo.toml", "rb"))["package"]["version"])')
arch=$(uname -m)
case "$arch" in x86_64|aarch64) ;; *) echo "Unsupported architecture: $arch" >&2; exit 1 ;; esac
out=${OUTPUT_DIR:-$root/linux/dist}
mkdir -p "$out"
out=$(cd "$out" && pwd)
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
app_id=com.lazarovco.BudgetWarden
artifacts=()

if [[ $format == all || $format == flatpak ]]; then
    # Stage only build inputs; never send local credentials or target directories
    # into the Flatpak sandbox. Include uncommitted source changes for local builds.
    python3 - "$root" "$work" <<'PY'
import json, os, pathlib, shutil, sys
root, work = map(pathlib.Path, sys.argv[1:])
source = work / "source"
for package in ("core", "linux"):
    dest = source / package
    dest.mkdir(parents=True)
    for name in ("Cargo.toml", "Cargo.lock", "build.rs", "src", "data"):
        path = root / package / name
        if path.is_dir():
            shutil.copytree(path, dest / name)
        elif path.is_file():
            shutil.copy2(path, dest / name)
manifest = json.loads((root / "linux/packaging/com.lazarovco.BudgetWarden.json").read_text())
# flatpak-builder does not inherit the host environment inside its build sandbox.
# Forward only the installed-app OAuth configuration embedded in the binary.
env = manifest["build-options"]["env"]
for name in ("BUDGET_WARDEN_GOOGLE_CLIENT_ID", "BUDGET_WARDEN_GOOGLE_CLIENT_SECRET",
             "BUDGET_WARDEN_GOOGLE_PICKER_URL"):
    if os.environ.get(name):
        env[name] = os.environ[name]
(work / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
PY
    (
        cd "$work/source"
        mkdir -p .cargo
        # BoltFFI macros run cargo metadata against core independently, so its
        # lockfile's dependencies must also be available in the offline sandbox.
        cargo vendor --locked --manifest-path linux/Cargo.toml \
            --sync core/Cargo.toml vendor > .cargo/config.toml
    )
    flatpak-builder --user --force-clean --state-dir="$work/flatpak-state" --repo="$work/repo" \
        "$work/flatpak-build" "$work/manifest.json"
    artifact="Budget-Warden-$version-$arch.flatpak"
    flatpak build-bundle --runtime-repo=https://flathub.org/repo/flathub.flatpakrepo \
        "$work/repo" "$out/$artifact" "$app_id" stable
    artifacts+=("$artifact")
fi

if [[ $format == all || $format == appimage ]]; then
    cargo build --locked --release --manifest-path linux/Cargo.toml --target-dir "$work/target"
    appdir="$work/AppDir"
    install -Dm755 "$work/target/release/budget-warden-linux" "$appdir/usr/bin/budget-warden-linux"
    install -Dm644 "linux/data/$app_id.desktop" "$appdir/usr/share/applications/$app_id.desktop"
    install -Dm644 "linux/data/icons/hicolor/scalable/apps/$app_id.svg" \
        "$appdir/usr/share/icons/hicolor/scalable/apps/$app_id.svg"
    # appimagetool requires a raster .DirIcon, even when the desktop uses SVG.
    png="$appdir/usr/share/icons/hicolor/256x256/apps/$app_id.png"
    mkdir -p "$(dirname "$png")"
    rsvg-convert --width=256 --height=256 \
        "linux/data/icons/hicolor/scalable/apps/$app_id.svg" --output="$png"
    install -m644 "$png" "$appdir/$app_id.png"
    ln -s "$app_id.png" "$appdir/.DirIcon"
    install -Dm644 "linux/data/$app_id.metainfo.xml" "$appdir/usr/share/metainfo/$app_id.metainfo.xml"
    install -Dm644 linux/data/application-x-budget-warden-budget.xml \
        "$appdir/usr/share/mime/packages/$app_id.xml"
    artifact="Budget-Warden-$version-$arch.AppImage"
    (
        cd "$out"
        export ARCH="$arch" LINUXDEPLOY_OUTPUT_VERSION="$version" LDAI_OUTPUT="$artifact" DEPLOY_GTK_VERSION=4
        export APPIMAGE_EXTRACT_AND_RUN=1
        "$LINUXDEPLOY" --appdir "$appdir" \
            --desktop-file "$appdir/usr/share/applications/$app_id.desktop" \
            --icon-file "$png" --plugin gtk
        # The generic GTK plugin forces a GTK theme and X11. GTK_THEME prevents
        # libadwaita from applying its own stylesheet (including typography).
        # Keep its library/resource setup, but let libadwaita and GTK select
        # styling and the display backend. Split deployment from export so the
        # generated hook can be adjusted before it is sealed in the AppImage.
        python3 - "$appdir/apprun-hooks/linuxdeploy-plugin-gtk.sh" <<'PY'
import pathlib, sys
hook = pathlib.Path(sys.argv[1])
lines = hook.read_text().splitlines(keepends=True)
hook.write_text("".join(line for line in lines
                        if not line.startswith(("export GTK_THEME=", "export GDK_BACKEND="))))
PY
        "$LINUXDEPLOY" --appdir "$appdir" --output appimage
    )
    artifacts+=("$artifact")
fi
(
    cd "$out"
    sha256sum "${artifacts[@]}" > "SHA256SUMS-$format"
)
for artifact in "${artifacts[@]}"; do
    printf 'Created %s/%s\n' "$out" "$artifact"
done
