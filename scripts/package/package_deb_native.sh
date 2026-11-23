#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

# Build the opencode DEB provider for the v2 native mainline.
#
# Built from artifacts/transplant/<ver>/opencode-native-tui (revived v2 Bun
# standalone with the bionic libopentui.so grafted in, official update channel
# stripped). This package IS the plain `opencode` name and upgrades over the
# old v1 packages of the same name.
#
# Layout:
#   bin/opencode                       launcher (update notice, upgrade/uninstall)
#   lib/opencode2/runtime/opencode     v2 Bun runtime (bionic-only)
#   lib/opencode2/install.sh           `opencode upgrade` handler
#
# Native line constraints (documented in the package description):
#   - zero glibc runtime dependencies (pure Bionic)
#   - requires Android API >= 31 for the TUI library (libopentui 0.8.4)
#   - full TUI via the bionic libopentui.so built by CI

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
MAINTAINER="${MAINTAINER:-DARKBOYJYOTI (termux-opencode)}"
TRANSPLANT_ROOT="${TRANSPLANT_ROOT:-$ROOT_DIR/artifacts/transplant}"

command -v dpkg-deb >/dev/null 2>&1 || {
	echo "Error: dpkg-deb not found" >&2
	exit 1
}
if [[ -z "${ARCH_DEB:-}" ]]; then
	ARCH_DEB="$(dpkg --print-architecture 2>/dev/null || echo aarch64)"
fi

# Version: explicit VERSION wins, else resolve the single transplant build.
if [[ -z "${VERSION:-}" ]]; then
	shopt -s nullglob
	_builds=("$TRANSPLANT_ROOT"/*)
	shopt -u nullglob
	if [[ ${#_builds[@]} -eq 0 ]]; then
		echo "Error: no transplant builds under $TRANSPLANT_ROOT (run: make transplant VER=<x>)" >&2
		exit 1
	fi
	if [[ ${#_builds[@]} -gt 1 ]]; then
		echo "Error: multiple transplant builds found; set VERSION=<x> explicitly:" >&2
		printf '  %s\n' "${_builds[@]}" >&2
		exit 1
	fi
	VERSION="$(basename "${_builds[0]}")"
fi
# task-tui-common-fix: prefer opencode-native-tui (post-TUI-swap product,
# seccomp-hardened by seccomp-harden) with revived as fallback.
NATIVE_BIN="$TRANSPLANT_ROOT/$VERSION/opencode-native-tui"
[[ -x "$NATIVE_BIN" ]] || NATIVE_BIN="$TRANSPLANT_ROOT/$VERSION/opencode-native-revived"
[[ -x "$NATIVE_BIN" ]] || {
	echo "Error: missing native runtime $NATIVE_BIN (run: make transplant VER=$VERSION)" >&2
	exit 1
}

# This repository ships v2 as the plain `opencode` command; the old v1
# packages (`opencode` 1.x, legacy `opencode1*`) are replaced on install.
PKG_NAME="opencode"
PKG_CONFLICTS="opencode1, opencode1-wrapper, opencode1-compressed, opencode1-wrapper-standalone, opencode-wrapper"
PKG_REPLACES="opencode1, opencode1-wrapper-standalone"

# Official update channel must be structurally absent: this repository's
# releases are the only supported upgrade path (AGENTS.md section 5). Verify
# every known upstream anchor set is fully stripped; fail closed otherwise.
command -v python3 >/dev/null 2>&1 || {
	echo "Error: python3 is required to verify the stripped update channel" >&2
	exit 1
}
python3 "$ROOT_DIR/tools/transplant/strip_official_update.py" --verify "$NATIVE_BIN" || {
	echo "Error: refusing to package a runtime with the official update channel present" >&2
	echo "       run: python3 tools/transplant/strip_official_update.py $NATIVE_BIN" >&2
	exit 1
}

# hook_enabled NAME DEFAULT-GLOB — packaging hook registry resolver (Makefile:
# HOOKS_ENABLE / HOOKS_DISABLE / HOOK_*_VERSIONS). HOOKS_DISABLE wins over
# HOOKS_ENABLE; otherwise the hook's default version-glob decides.
hook_enabled() {
	case " ${HOOKS_DISABLE:-} " in *" $1 "*) return 1 ;; esac
	case " ${HOOKS_ENABLE:-} " in *" $1 "*) return 0 ;; esac
	case "${VERSION:-}" in $2) return 0 ;; *) return 1 ;; esac
}

DEB_ROOT="$ROOT_DIR/packing/dpkg-native/work"
OUT_DIR="$ROOT_DIR/packing/dpkg-native"
OUT_FILE="$OUT_DIR/${PKG_NAME}_${VERSION}_${ARCH_DEB}.deb"
DESCRIPTION="OpenCode v2 native Bionic CLI for Android/Termux (termux-opencode build). Full TUI via bionic libopentui.so; zero glibc dependencies."

rm -rf "$DEB_ROOT"
mkdir -p "$DEB_ROOT/DEBIAN" "$DEB_ROOT$PREFIX/bin" "$OUT_DIR"
chmod 755 "$DEB_ROOT" "$DEB_ROOT/DEBIAN"

BIN_NAME="opencode"
[[ -f "$ROOT_DIR/scripts/opencode-launcher.sh" ]] || {
	echo "Error: scripts/opencode-launcher.sh missing (launcher source)" >&2; exit 1; }
# Layered layout: the launcher owns the update notice / upgrade / uninstall
# handling, the runtime lives under lib/opencode2/runtime/.
install -D -m755 "$NATIVE_BIN" "$DEB_ROOT$PREFIX/lib/opencode2/runtime/opencode"
install -D -m755 "$ROOT_DIR/scripts/opencode-launcher.sh" "$DEB_ROOT$PREFIX/bin/opencode"
# The `opencode upgrade` subcommand is served by the launcher from the shipped
# installer — it installs this repository's releases, never upstream's.
[[ -f "$ROOT_DIR/install.sh" ]] || {
	echo "Error: install.sh missing (upgrade handler source)" >&2; exit 1; }
install -D -m755 "$ROOT_DIR/install.sh" "$DEB_ROOT$PREFIX/lib/opencode2/install.sh"
echo "Packaged install.sh (opencode upgrade handler)"
# The v2 runtime needs no seccomp shim (official Bun 1.4.4 Android build does
# not issue the trapping close_range call that broke v1 on 4.14 kernels).
if grep -aqF libopencode-crhandler.so "$NATIVE_BIN"; then
	echo "Note: v2 runtime unexpectedly references libopencode-crhandler.so; not shipped" >&2
fi

cat >"$DEB_ROOT/DEBIAN/control" <<EOF
Package: $PKG_NAME
Version: $VERSION${DEB_REV:-}
Architecture: $ARCH_DEB
Maintainer: $MAINTAINER
Section: utils
Priority: optional
Depends:
Conflicts: $PKG_CONFLICTS
Replaces: ${PKG_REPLACES:-opencode1-wrapper-standalone}
Description: $DESCRIPTION
EOF

INSTALLED_SIZE=$(du -sk "$DEB_ROOT" | cut -f1)
echo "Installed-Size: $INSTALLED_SIZE" >>"$DEB_ROOT/DEBIAN/control"

cat >"$DEB_ROOT/DEBIAN/postinst" <<'POSTINST'
#!/data/data/com.termux/files/usr/bin/bash
set -e
# Install-time hygiene: never inherit ambient XDG roots (a pre-isolated
# environment would double-nest the migration paths). The migration helper
# also normalizes them, but postinst must not depend on the caller at all.
unset XDG_CONFIG_HOME XDG_DATA_HOME XDG_CACHE_HOME XDG_STATE_HOME
POSTINST
# stale-serve-kill hook (issue #17): gated by the packaging hook registry —
# default scope v2 native 2.0.[0-3] only; HOOKS_ENABLE / HOOKS_DISABLE override.
if hook_enabled stale-serve-kill "2.0.[0-3]"; then
  cat >>"$DEB_ROOT/DEBIAN/postinst" <<'POSTINST_HOOK'
# Stale-service cleanup: an upgrade replaces the binary while an old `serve`
# daemon may still hold the background-service socket -> the new TUI times
# out waiting for it. Kill only THIS package binary's serve processes; the
# other generation's runtime path differs and is never matched.
P="$(printf '%s' "${DPKG_MAINTSCRIPT_PACKAGE:-}")"
case "$P" in
  opencode)  SRV="$PREFIX/lib/opencode2/runtime/opencode" ;;
  *)         SRV="" ;;
esac
if [ -n "$SRV" ] && pgrep -f "^$SRV( |$)" >/dev/null 2>&1; then
  pkill -f "^$SRV( |$)" 2>/dev/null || true
  echo "Stopped stale $(basename "$SRV") serve processes (pre-upgrade instances)."
fi
POSTINST_HOOK
fi
cat >>"$DEB_ROOT/DEBIAN/postinst" <<'POSTINST'
# stale-runtime-quarantine: $PREFIX/lib/opencode/runtime/opencode may be a
# pre-v12.1 v1-era leftover (e.g. a June 1.17.9) that no current package owns.
# Conservative rename-backup ONLY if all hold: file exists, unowned
# (dpkg -S finds no package), and same-arch (aarch64 ELF) as this runtime.
# NEVER rm user files; the owner (user) decides deletion.
STALE="$PREFIX/lib/opencode/runtime/opencode"
if [ -f "$STALE" ] && command -v file >/dev/null 2>&1; then
  if ! dpkg -S "$STALE" >/dev/null 2>&1; then
    case "$(file -b "$STALE")" in
      *ELF*aarch64*|*aarch64*ELF*)
        BAK="$STALE.stale-$(date +%Y%m%d)"
        if mv -n "$STALE" "$BAK" 2>/dev/null && [ ! -f "$STALE" ]; then
          echo "Quarantined unowned stale runtime: $STALE -> $BAK"
          echo "(no dpkg package owns it; delete manually if unneeded)"
        fi
        ;;
    esac
  fi
fi

# v2 reads the same official plain data layout as v1 (<root>/opencode). No
# data migration runs here: user data is never moved or deleted by packaging.
echo "OpenCode v2 (termux-opencode build) installed."
echo "Data layout unchanged: ${XDG_CONFIG_HOME:-$HOME/.config}/opencode etc."
exit 0
POSTINST
chmod 755 "$DEB_ROOT/DEBIAN/postinst"

dpkg-deb --build "$DEB_ROOT" "$OUT_FILE"
echo "Native DEB package created: $OUT_FILE"
