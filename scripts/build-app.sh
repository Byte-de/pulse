#!/usr/bin/env bash
#
# build-app.sh — builds the distributable Byte Pulse app bundle (dist/Pulse.app).
#
# Usage:
#   ./scripts/build-app.sh            build dist/Pulse.app
#   ./scripts/build-app.sh --install  build + install to /Applications/Pulse.app
#   ./scripts/build-app.sh --run      build + open dist/Pulse.app
#
# Environment overrides:
#   SWIFT_BUILD_FLAGS   extra flags appended to `swift build` (e.g. "--arch arm64")
#   BINARY_OVERRIDE     path to a prebuilt executable; skips `swift build`
#                       entirely (for CI / packaging tests only)
#
# Pipeline: swift build → assemble bundle → Info.plist + PkgInfo → icon
# (cached render via scripts/make-icon.swift) → ad-hoc codesign LAST
# (adding files after signing breaks the seal — docs/RESEARCH/swiftui-macos26.md §6).

set -euo pipefail

APP_NAME="Pulse"
BUNDLE_ID="de.byte.pulse"
VERSION="1.0.1"
BUILD="2"
MIN_OS="26.0"

# ---------------------------------------------------------------- pretty output

if [ -t 1 ]; then
    GREEN=$'\033[32m'; RED=$'\033[31m'; DIM=$'\033[2m'; BOLD=$'\033[1m'; RESET=$'\033[0m'
else
    GREEN=""; RED=""; DIM=""; BOLD=""; RESET=""
fi
step() { printf '%s→ %s%s\n' "$DIM" "$*" "$RESET"; }
ok()   { printf '%s✓%s %s\n' "$GREEN" "$RESET" "$*"; }
die()  { printf '%s✗ error:%s %s\n' "$RED" "$RESET" "$*" >&2; exit 1; }

on_exit() {
    rc=$?
    if [ "$rc" -ne 0 ]; then
        printf '%s✗ build failed (exit %d)%s\n' "$RED" "$rc" "$RESET" >&2
    fi
    exit "$rc"
}
trap on_exit EXIT

# ---------------------------------------------------------------- locations

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "$REPO_ROOT"   # works no matter where it is invoked from

DIST_DIR="${REPO_ROOT}/dist"
APP_BUNDLE="${DIST_DIR}/${APP_NAME}.app"
CONTENTS="${APP_BUNDLE}/Contents"
ICON_CACHE_DIR="${REPO_ROOT}/.build-icon"
ICON_SRC="${SCRIPT_DIR}/make-icon.swift"

# ---------------------------------------------------------------- arguments

DO_INSTALL=0
DO_RUN=0
for arg in "$@"; do
    case "$arg" in
        --install) DO_INSTALL=1 ;;
        --run)     DO_RUN=1 ;;
        -h|--help)
            sed -n '2,16p' "${SCRIPT_DIR}/build-app.sh" | sed 's/^# \{0,1\}//'
            trap - EXIT; exit 0 ;;
        *) die "unknown argument: ${arg} (use --install or --run)" ;;
    esac
done

printf '%sByte Pulse — packaging %s %s (build %s)%s\n' "$BOLD" "$APP_NAME" "$VERSION" "$BUILD" "$RESET"

# ---------------------------------------------------------------- 1. binary

if [ -n "${BINARY_OVERRIDE:-}" ]; then
    [ -f "$BINARY_OVERRIDE" ] && [ -x "$BINARY_OVERRIDE" ] \
        || die "BINARY_OVERRIDE is not an executable file: ${BINARY_OVERRIDE}"
    BINARY_PATH="$BINARY_OVERRIDE"
    ok "using BINARY_OVERRIDE (swift build skipped): ${BINARY_OVERRIDE}"
else
    step "swift build -c release --product ${APP_NAME} ${SWIFT_BUILD_FLAGS:-}"
    # SWIFT_BUILD_FLAGS is intentionally word-split:
    # shellcheck disable=SC2086
    swift build -c release --product "$APP_NAME" ${SWIFT_BUILD_FLAGS:-}
    # shellcheck disable=SC2086
    BIN_DIR="$(swift build -c release --product "$APP_NAME" ${SWIFT_BUILD_FLAGS:-} --show-bin-path)"
    BINARY_PATH="${BIN_DIR}/${APP_NAME}"
    [ -x "$BINARY_PATH" ] || die "built binary not found at ${BINARY_PATH}"
    ok "release binary: ${BINARY_PATH}"
fi

# ---------------------------------------------------------------- 2. icon (cached)

ICON_SUM_FILE="${ICON_CACHE_DIR}/make-icon.swift.sha256"
ICON_ICNS="${ICON_CACHE_DIR}/AppIcon.icns"
ICON_SUM="$(shasum -a 256 "$ICON_SRC" | awk '{print $1}')"

if [ -f "$ICON_ICNS" ] && [ -f "$ICON_SUM_FILE" ] && [ "$(cat "$ICON_SUM_FILE")" = "$ICON_SUM" ]; then
    ok "icon cache hit (.build-icon/AppIcon.icns)"
else
    step "rendering app icon (scripts/make-icon.swift)"
    mkdir -p "$ICON_CACHE_DIR"
    rm -f "$ICON_SUM_FILE"
    swift "$ICON_SRC" "$ICON_CACHE_DIR"
    printf '%s' "$ICON_SUM" > "$ICON_SUM_FILE"   # written only after success
    ok "AppIcon.icns rendered"
fi
[ -s "$ICON_ICNS" ] || die "icon missing: ${ICON_ICNS}"

# ---------------------------------------------------------------- 3. assemble bundle

step "assembling ${APP_BUNDLE#"$REPO_ROOT"/}"
rm -rf "$APP_BUNDLE"
mkdir -p "${CONTENTS}/MacOS" "${CONTENTS}/Resources"

cp "$BINARY_PATH" "${CONTENTS}/MacOS/${APP_NAME}"
chmod 755 "${CONTENTS}/MacOS/${APP_NAME}"

# SPM resource bundle (Bundle.module assets, e.g. the Byte mark). It lives next
# to the built binary and must ship in Contents/Resources for Bundle.module to
# resolve inside the .app.
RESOURCE_BUNDLE="$(dirname "$BINARY_PATH")/${APP_NAME}_${APP_NAME}.bundle"
if [ -d "$RESOURCE_BUNDLE" ]; then
  cp -R "$RESOURCE_BUNDLE" "${CONTENTS}/Resources/"
fi

cat > "${CONTENTS}/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleExecutable</key>
	<string>${APP_NAME}</string>
	<key>CFBundleIdentifier</key>
	<string>${BUNDLE_ID}</string>
	<key>CFBundleName</key>
	<string>${APP_NAME}</string>
	<key>CFBundleDisplayName</key>
	<string>${APP_NAME}</string>
	<key>CFBundleShortVersionString</key>
	<string>${VERSION}</string>
	<key>CFBundleVersion</key>
	<string>${BUILD}</string>
	<key>LSMinimumSystemVersion</key>
	<string>${MIN_OS}</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSHumanReadableCopyright</key>
	<string>© 2026 Byte</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundleIconName</key>
	<string>AppIcon</string>
	<key>LSApplicationCategoryType</key>
	<string>public.app-category.developer-tools</string>
	<key>NSPrincipalClass</key>
	<string>NSApplication</string>
</dict>
</plist>
PLIST
plutil -lint "${CONTENTS}/Info.plist" > /dev/null || die "Info.plist failed plutil -lint"

printf 'APPL????' > "${CONTENTS}/PkgInfo"
cp "$ICON_ICNS" "${CONTENTS}/Resources/AppIcon.icns"
ok "bundle assembled (Info.plist lint OK, icon + PkgInfo in place)"

# ---------------------------------------------------------------- 4. codesign (LAST)

step "codesign --force --sign - (ad-hoc)"
codesign --force --sign - "$APP_BUNDLE" 2> /dev/null \
    || codesign --force --sign - "$APP_BUNDLE"   # re-run loudly if it failed
codesign --verify --strict "$APP_BUNDLE" || die "codesign verification failed"
ok "signed + verified (ad-hoc)"

ok "${APP_BUNDLE#"$REPO_ROOT"/} ready"

# ---------------------------------------------------------------- 5. --install

if [ "$DO_INSTALL" -eq 1 ]; then
    TARGET="/Applications/${APP_NAME}.app"
    step "installing to ${TARGET}"
    pkill -x "$APP_NAME" 2> /dev/null || true
    if [ -e "$TARGET" ]; then
        EXISTING_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
            "${TARGET}/Contents/Info.plist" 2> /dev/null || true)"
        if [ "$EXISTING_ID" != "$BUNDLE_ID" ]; then
            die "refusing to remove ${TARGET}: its CFBundleIdentifier ('${EXISTING_ID:-<unreadable>}') is not ${BUNDLE_ID}"
        fi
        rm -rf "$TARGET"
    fi
    ditto "$APP_BUNDLE" "$TARGET"
    ok "installed: ${TARGET}"
    printf '\n  Launch it with:  %sopen %s%s\n\n' "$BOLD" "$TARGET" "$RESET"
fi

# ---------------------------------------------------------------- 6. --run

if [ "$DO_RUN" -eq 1 ]; then
    step "launching ${APP_BUNDLE#"$REPO_ROOT"/}"
    open "$APP_BUNDLE"
    ok "launched"
fi
