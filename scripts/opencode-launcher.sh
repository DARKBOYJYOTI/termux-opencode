#!/data/data/com.termux/files/usr/bin/bash
# opencode launcher — termux-opencode build (v1 runtime, plain `opencode` name).
#
# Why: the v1 runtime hardcodes the plain `opencode/` roots (live-fd verified;
# OPENCODE_CONFIG_DIR and friends are enumerated but NOT consumed). The four
# XDG_*_HOME exports re-root every path under an `opencode1/` isolation prefix;
# the runtime then appends its own `opencode/` suffix, landing in the NESTED
# layout migrate-to-opencode1.sh isolate maintains: <root>/opencode1/opencode/.
# The `opencode1/` prefix is kept so existing user data survives the rename
# from the legacy `opencode1` command — only the user-facing command changed.
#
# LD_LIBRARY_PATH covers DT_RUNPATH $ORIGIN/../lib/opencode after the runtime
# moves under lib/opencode1/runtime/; both roots are listed so every package
# layout resolves (absent dirs are harmless: the dynamic linker just skips them).
set -euo pipefail
P="${PREFIX:-/data/data/com.termux/files/usr}"
# Keep GitHub CLI authentication reachable after isolating OpenCode's XDG paths.
export GH_CONFIG_DIR="${GH_CONFIG_DIR:-$HOME/.config/gh}"
# Update-channel policy: packages from this repository are the only supported
# upgrade path. Disable the official-channel update checks and notices by
# default (upstream flag: OPENCODE_DISABLE_AUTOUPDATE, truthy = "1"/"true").
# Explicit `opencode upgrade` still works; unset or set to 0 to re-enable.
export OPENCODE_DISABLE_AUTOUPDATE="${OPENCODE_DISABLE_AUTOUPDATE:-1}"
# Normalize XDG roots first: strip a trailing `/opencode1` so an
# already-isolated environment cannot double-nest paths (idempotent).
_norm_root() { printf '%s' "${1%/opencode1}"; }
export XDG_CONFIG_HOME="$(_norm_root "${XDG_CONFIG_HOME:-$HOME/.config}")/opencode1"
export XDG_DATA_HOME="$(_norm_root "${XDG_DATA_HOME:-$HOME/.local/share}")/opencode1"
export XDG_CACHE_HOME="$(_norm_root "${XDG_CACHE_HOME:-$HOME/.cache}")/opencode1"
export XDG_STATE_HOME="$(_norm_root "${XDG_STATE_HOME:-$HOME/.local/state}")/opencode1"
export LD_LIBRARY_PATH="$P/lib/opencode:$P/lib/opencode1:$P/lib/opencode1/pty${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

# service-port split (readiness fix, evidence: tools/opencode-readiness-fix/):
# both v2 generations default the managed service port to 0xc0de=49374, but the
# XDG isolation keeps their registration files apart — a plain-generation daemon
# squatting 49374 is invisible to this generation's discovery, so every
# `serve --service` contender dies of EADDRINUSE and the TUI handshake stalls
# until ensure()'s 120s deadline ("Timed out waiting for the background
# service"). Bootstrap a per-generation port (49376) in this generation's
# service config: absent file -> write one; existing file without a "port" key
# -> inject one (opencode writes pretty JSON whose first line is always "{").
# Best-effort: any failure falls back to the stock default port.
CFG_DIR="${XDG_CONFIG_HOME}/opencode"
CFG_FILE="${CFG_DIR}/service.json"
if [ ! -f "$CFG_FILE" ]; then
	mkdir -p "$CFG_DIR" 2>/dev/null || true
	printf '{"port": 49376}\n' > "$CFG_FILE" 2>/dev/null || true
elif ! grep -q '"port"' "$CFG_FILE" 2>/dev/null; then
	sed -i '1s/^{$/{\n  "port": 49376,/' "$CFG_FILE" 2>/dev/null || true
fi

# pty splice (optional asset, backward compatible): when the compressed package
# ships the patched musl librust_pty (bun-pty 0.4.11 splice — see
# tools/bun-pty-splice/ and docs/compressed-line.md), point bun-pty's
# BUN_PTY_LIB probe at it so the runtime dlopens the bionic-compatible build
# instead of failing on the inlined asset. Its DT_NEEDED shim.so resolves via
# the pty dir added to LD_LIBRARY_PATH above. Old packages without the asset
# are unaffected (no export).
if [ -f "$P/lib/opencode1/pty/librust_pty_arm64_musl_patched.so" ]; then
	export BUN_PTY_LIB="$P/lib/opencode1/pty/librust_pty_arm64_musl_patched.so"
fi

# epoll compat shim (optional asset, backward compatible): pre-#32490 bun
# builds (v1.4.0 34cbb9a40, as shipped in 1.18.32-4) call epoll_pwait2
# (syscall 441, kernel >= 5.1) via libc::syscall and crash on older kernels
# (oscar 3.18.140: TUI SIGSEGV ~4.4s, see task-v1rebuild.txt). The shim
# translates 441 -> epoll_pwait with a timespec->ms conversion. Injected via
# LD_PRELOAD ONLY when the package shipped the asset; packages built before
# the asset are unaffected (no export).
if [ -f "$P/lib/opencode1/libepoll-compat.so" ]; then
	export LD_PRELOAD="$P/lib/opencode1/libepoll-compat.so${LD_PRELOAD:+:$LD_PRELOAD}"
fi

# This repository's release notice: once a day at most, cached, TTY-only, and
# silent on any failure (offline, no curl, no release yet). Official-channel
# checks stay off (see OPENCODE_DISABLE_AUTOUPDATE above); this is the only
# update signal, and it points at this repository's releases.
# Opt out: TERMUX_OPENCODE_UPDATE_CHECK=0.
_termux_opencode_update_notice() {
	[ "${TERMUX_OPENCODE_UPDATE_CHECK:-1}" = "1" ] || return 0
	[ -t 1 ] || return 0
	command -v curl >/dev/null 2>&1 || return 0
	_installed="$(dpkg-query -W -f='${Version}' opencode 2>/dev/null || true)"
	[ -n "$_installed" ] || return 0
	_cache_dir="${XDG_CACHE_HOME}/opencode"
	_cache_file="$_cache_dir/update-check.json"
	_now="$(date +%s 2>/dev/null || echo 0)"
	case "$_now" in ''|*[!0-9]*) return 0 ;; esac
	_last=0; _latest=""
	if [ -f "$_cache_file" ]; then
		read -r _last _latest < "$_cache_file" 2>/dev/null || true
	fi
	case "$_last" in ''|*[!0-9]*) _last=0 ;; esac
	if [ "$_now" -ge "$((_last + 86400))" ]; then
		_tag="$(curl -fsSL --max-time 3 https://api.github.com/repos/DARKBOYJYOTI/termux-opencode/releases/latest 2>/dev/null | grep -m1 '"tag_name"' | sed 's/.*"tag_name": *"//;s/".*//' || true)"
		case "$_tag" in
			opencode-*) _latest="${_tag#opencode-}" ;;
			*) _latest="" ;;
		esac
		if [ -n "$_latest" ]; then
			mkdir -p "$_cache_dir" 2>/dev/null || true
			printf '%s %s\n' "$_now" "$_latest" > "$_cache_file" 2>/dev/null || true
		fi
	fi
	[ -n "$_latest" ] || return 0
	[ "$_latest" = "$_installed" ] && return 0
	_newest="$(printf '%s\n%s\n' "$_installed" "$_latest" | sort -V | tail -n1)"
	if [ "$_newest" = "$_latest" ]; then
		printf 'Update available: opencode %s (installed %s).\n' "$_latest" "$_installed" >&2
		printf 'Get it: https://github.com/DARKBOYJYOTI/termux-opencode/releases (dpkg -i opencode_%s_aarch64.deb)\n' "$_latest" >&2
	fi
	return 0
}
_termux_opencode_update_notice

# `opencode upgrade` serves this repository's releases — never the upstream
# flow (which would overwrite this hardened runtime with an official build).
# `opencode upgrade [version]` reuses the shipped installer; everything else
# passes through to the runtime untouched.
if [ "${1:-}" = "upgrade" ]; then
	shift
	_installer="$P/lib/opencode1/install.sh"
	if [ ! -f "$_installer" ]; then
		echo "opencode: upgrade handler missing ($P/lib/opencode1/install.sh not shipped)" >&2
		exit 1
	fi
	case "${1:-}" in
		-h|--help) exec bash "$_installer" --help < /dev/null ;;
		"") exec bash "$_installer" < /dev/null ;;
		*) exec bash "$_installer" -v "$1" < /dev/null ;;
	esac
fi

# runtime probe order: packaged layout first, then the legacy staged layout.
for _rt in "$P/lib/opencode1/runtime/opencode" "$P/lib/opencode/runtime/opencode"; do
	if [ -x "$_rt" ]; then
		exec "$_rt" "$@"
	fi
done
echo "opencode: runtime not found under $P/lib/opencode1/runtime or $P/lib/opencode/runtime" >&2
exit 127
