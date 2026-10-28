#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

# Build the opencode DEB provider (transplant revival line, native mainline).
#
# This package IS the plain `opencode` name (inherited by the native mainline
# per the 27/28 package-rename decision). Built from
# artifacts/transplant/<ver>/opencode-native-revived; conflicts with the glibc
# appendix package (opencode-wrapper) and the compressed transitional package
# (opencode-compressed): installing one replaces the other.
#
# Native line constraints (documented in the package description):
#   - zero glibc runtime dependencies (pure Bionic)
#   - requires Android API >= 28
#   - full TUI via bionic libopentui.so (W10a deep smoke 5/5); zero glibc runtime deps

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

# This repository ships v1 (1.x) as the plain `opencode` command — the rename
# from `opencode1` keeps every integration (plugins, MCP, scripts) working
# without manual patching. The legacy `opencode1` packages are replaced.
case "$VERSION" in
	1.*) PKG_NAME="opencode"; PKG_CONFLICTS="opencode1, opencode1-wrapper, opencode1-compressed, opencode1-wrapper-standalone, opencode-wrapper"; PKG_REPLACES="opencode1, opencode1-wrapper-standalone" ;;
	*)   PKG_NAME="opencode";  PKG_CONFLICTS="opencode-wrapper"; PKG_REPLACES="" ;;
esac

# The v1 native family must carry the self-activating Android seccomp handler.
# Without it, Android's zygote filter traps Bun's close_range syscall with
# SIGSYS before even `opencode --version` can run (observed on Android 12 / 4.14).
if [[ "$VERSION" == 1.* ]] && ! grep -aqF libopencode-crhandler.so "$NATIVE_BIN"; then
	echo "Error: refusing to package an unhardened opencode native runtime" >&2
	echo "       run the native transplant + harden-native steps before packaging" >&2
	exit 1
fi

# Official update channel must be structurally absent: this repository's
# releases are the only supported upgrade path (AGENTS.md section 5). Verify
# every known upstream anchor set is fully stripped; fail closed otherwise.
if [[ "$VERSION" == 1.* ]]; then
	command -v python3 >/dev/null 2>&1 || {
		echo "Error: python3 is required to verify the stripped update channel" >&2
		exit 1
	}
	python3 "$ROOT_DIR/tools/transplant/strip_official_update.py" --verify "$NATIVE_BIN" || {
		echo "Error: refusing to package a runtime with the official update channel present" >&2
		echo "       run: python3 tools/transplant/strip_official_update.py $NATIVE_BIN" >&2
		exit 1
	}
fi

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
if [[ "$VERSION" == 1.* ]]; then
	DESCRIPTION="OpenCode v1 native Bionic CLI for Android/Termux (termux-opencode build)."
else
	DESCRIPTION="OpenCode native Bionic mainline for Android/Termux. Full TUI via bionic libopentui.so; zero glibc dependencies."
fi

rm -rf "$DEB_ROOT"
mkdir -p "$DEB_ROOT/DEBIAN" "$DEB_ROOT$PREFIX/bin" "$OUT_DIR"
chmod 755 "$DEB_ROOT" "$DEB_ROOT/DEBIAN"

if [[ "$VERSION" == 1.* ]]; then BIN_NAME="opencode"; LIB_DIR="opencode1"; else BIN_NAME="opencode"; LIB_DIR="opencode"; fi
[[ -f "$ROOT_DIR/scripts/opencode-launcher.sh" ]] || {
	echo "Error: scripts/opencode-launcher.sh missing (v1 launcher source)" >&2; exit 1; }
if [[ "$VERSION" == 1.* ]]; then
	# v1 layered — bare runtime under lib/opencode1/runtime/ (DT_RUNPATH
	# $ORIGIN/../lib/opencode resolved via the launcher's LD_LIBRARY_PATH) +
	# the XDG-isolating launcher at bin/opencode. The lib/opencode1 directory
	# name is an internal detail kept for DT_RUNPATH compatibility; the
	# user-facing command is `opencode`.
	install -D -m755 "$NATIVE_BIN" "$DEB_ROOT$PREFIX/lib/opencode1/runtime/opencode"
	install -D -m755 "$ROOT_DIR/scripts/opencode-launcher.sh" "$DEB_ROOT$PREFIX/bin/opencode"
else
	install -m755 "$NATIVE_BIN" "$DEB_ROOT$PREFIX/bin/$BIN_NAME"
fi
# v12.0: the postinst migration branch needs migrate-to-opencode1.sh on the
# user's PATH — ship it alongside (v1 packages only; v2 branch never calls it).
if [[ "$VERSION" == 1.* ]]; then
	install -m755 "$ROOT_DIR/scripts/migrate-to-opencode1.sh" "$DEB_ROOT$PREFIX/bin/migrate-to-opencode1.sh"
	echo "Packaged migrate-to-opencode1.sh (v1 migration helper)"
fi
# The `opencode upgrade` subcommand is served by the launcher from the shipped
# installer — it installs this repository's releases, never upstream's.
if [[ "$VERSION" == 1.* ]]; then
	[[ -f "$ROOT_DIR/install.sh" ]] || {
		echo "Error: install.sh missing (upgrade handler source)" >&2; exit 1; }
	install -D -m755 "$ROOT_DIR/install.sh" "$DEB_ROOT$PREFIX/lib/opencode1/install.sh"
	echo "Packaged install.sh (opencode upgrade handler)"
fi

# W11: ship the self-activating seccomp shim when the binary references it
# (DT_NEEDED libopencode-crhandler.so). It must land in $PREFIX/lib/opencode/
# to satisfy the binary's DT_RUNPATH $ORIGIN/../lib/opencode.
if grep -aqF libopencode-crhandler.so "$NATIVE_BIN"; then
	SHIM_SO="$(dirname "$NATIVE_BIN")/libopencode-crhandler.so"
	if [[ ! -f "$SHIM_SO" ]]; then
		echo "Error: hardened binary references libopencode-crhandler.so but $SHIM_SO is missing" >&2
		echo "       (run: make seccomp-harden VER=$VERSION)" >&2
		exit 1
	fi
	# shim dir is pinned to lib/opencode (the binary's DT_RUNPATH
	# $ORIGIN/../lib/opencode) — renaming the dir with the opencode1
	# package rename broke CANNOT LINK for any hardened v1 build (#23-adjacent).
	mkdir -p "$DEB_ROOT$PREFIX/lib/opencode"
	install -m644 "$SHIM_SO" "$DEB_ROOT$PREFIX/lib/opencode/libopencode-crhandler.so"
	echo "Packaging seccomp shim: $SHIM_SO -> $PREFIX/lib/opencode/"
else
	echo "Note: binary is not seccomp-hardened; shipping without libopencode-crhandler.so"
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
  opencode)  SRV="$PREFIX/lib/opencode1/runtime/opencode" ;;
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

# v1 data hook: the packaged runtime reads the OFFICIAL plain layout
# (<root>/opencode). If legacy nested opencode1 data exists, move it back
# (conflicting plain dirs are backed aside, never deleted).
case "${PKG_NAME:-$DPKG_MAINTSCRIPT_PACKAGE}" in
  opencode)
    echo "OpenCode v1 (termux-opencode build) installed."
    if command -v migrate-to-opencode1.sh >/dev/null 2>&1; then
      migrate-to-opencode1.sh replain || echo "Data layout check reported issues — data left untouched (see above)."
    else
      echo "Migration helper not on PATH; skipping data layout check."
    fi
    ;;
esac
exit 0
POSTINST
chmod 755 "$DEB_ROOT/DEBIAN/postinst"

dpkg-deb --build "$DEB_ROOT" "$OUT_FILE"
echo "Native DEB package created: $OUT_FILE"
