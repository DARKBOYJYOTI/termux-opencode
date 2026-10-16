#!/data/data/com.termux/files/usr/bin/bash
# opencode launcher — termux-opencode build (v1 runtime, plain `opencode` name).
#
# Data layout is the OFFICIAL opencode structure: the v1 runtime reads the
# plain XDG roots (`<root>/opencode`), exactly like upstream. This launcher
# sets no XDG re-rooting — every integration (plugins, MCP, scripts) works
# with unpatched official paths.
#
# LD_LIBRARY_PATH covers DT_RUNPATH $ORIGIN/../lib/opencode: the runtime
# binary lives under lib/opencode1/runtime/ (internal detail kept for loader
# compatibility), the shim under lib/opencode/. Absent dirs are harmless: the
# dynamic linker just skips them.
set -euo pipefail
P="${PREFIX:-/data/data/com.termux/files/usr}"
# Keep GitHub CLI authentication reachable for wrapped gh invocations.
export GH_CONFIG_DIR="${GH_CONFIG_DIR:-$HOME/.config/gh}"
# Update-channel policy: packages from this repository are the only supported
# upgrade path. Disable the official-channel update checks and notices by
# default (upstream flag: OPENCODE_DISABLE_AUTOUPDATE, truthy = "1"/"true").
export OPENCODE_DISABLE_AUTOUPDATE="${OPENCODE_DISABLE_AUTOUPDATE:-1}"
export LD_LIBRARY_PATH="$P/lib/opencode:$P/lib/opencode1:$P/lib/opencode1/pty${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

# Normalize an XDG root: strip a trailing `/opencode1` so an already-isolated
# environment resolves to the same official-plain paths (idempotent). Used
# only for paths this launcher computes itself (notice cache, purge roots) —
# the runtime reads ambient XDG untouched, i.e. the official layout.
_norm_root() { printf '%s' "${1%/opencode1}"; }

# pty splice (optional asset, backward compatible): when the package ships the
# patched musl librust_pty, point bun-pty's BUN_PTY_LIB probe at it so the
# runtime dlopens the bionic-compatible build instead of failing on the
# inlined asset. Old packages without the asset are unaffected (no export).
if [ -f "$P/lib/opencode1/pty/librust_pty_arm64_musl_patched.so" ]; then
	export BUN_PTY_LIB="$P/lib/opencode1/pty/librust_pty_arm64_musl_patched.so"
fi

# epoll compat shim (optional asset, backward compatible): old bun builds call
# epoll_pwait2 (syscall 441, kernel >= 5.1) and crash on older kernels. The
# shim translates 441 -> epoll_pwait. Injected via LD_PRELOAD ONLY when the
# package shipped the asset; packages without it are unaffected (no export).
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
	_cache_dir="$(_norm_root "${XDG_CACHE_HOME:-$HOME/.cache}")/opencode"
	_cache_file="$_cache_dir/update-check.json"
	_now="$(date +%s 2>/dev/null || echo 0)"
	case "$_now" in ''|*[!0-9]*) return 0 ;; esac
	_last=0; _latest=""
	if [ -f "$_cache_file" ]; then
		read -r _last _latest < "$_cache_file" 2>/dev/null || true
	fi
	case "$_last" in ''|*[!0-9]*) _last=0 ;; esac
	if [ "$_now" -ge "$((_last + 86400))" ]; then
		# Pure-bash extraction: piping curl into `grep -m1` lets grep close
		# the pipe early and kills curl with SIGPIPE (exit 23) — a timing flake.
		_response="$(curl -fsSL --max-time 3 https://api.github.com/repos/DARKBOYJYOTI/termux-opencode/releases/latest 2>/dev/null)" || _response=""
		_tag="${_response#*\"tag_name\": \"}"
		_tag="${_tag%%\"*}"
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
		printf 'Run: opencode upgrade  (or: https://github.com/DARKBOYJYOTI/termux-opencode/releases)\n' >&2
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

# `opencode uninstall` removes exactly what this repository installed — never
# the upstream flow (which deletes data dirs by default), never anything
# else. Default keeps all user data; `--purge-data` removes the four official
# data roots after confirmation (or `--force`). `--dry-run` only prints.
if [ "${1:-}" = "uninstall" ]; then
	shift
	_purge=0; _force=0; _dry=0
	for _arg in ${1:+"$@"}; do
		case "$_arg" in
			--purge-data) _purge=1 ;;
			--force|-f) _force=1 ;;
			--dry-run) _dry=1 ;;
			-h|--help)
				echo "Usage: opencode uninstall [--purge-data] [--force] [--dry-run]"
				echo "  default: remove the opencode package, keep all user data"
				echo "  --purge-data: also remove ~/.config/opencode, ~/.local/share/opencode,"
				echo "                ~/.cache/opencode, ~/.local/state/opencode"
				echo "  --force: skip the confirmation prompt   --dry-run: print only"
				exit 0 ;;
			*) echo "opencode: unknown uninstall option: $_arg" >&2; exit 1 ;;
		esac
	done
	_home="${HOME:?HOME is not set}"
	_roots="$(_norm_root "${XDG_CONFIG_HOME:-$_home/.config}")/opencode
$(_norm_root "${XDG_DATA_HOME:-$_home/.local/share}")/opencode
$(_norm_root "${XDG_CACHE_HOME:-$_home/.cache}")/opencode
$(_norm_root "${XDG_STATE_HOME:-$_home/.local/state}")/opencode"
	# Paranoia guard: every purge target must be an `opencode` dir under $HOME.
	_root=
	for _root in $_roots; do
		case "$_root" in
			"$_home"/*opencode*) ;;
			*) echo "opencode: refusing to touch unexpected path: $_root" >&2; exit 1 ;;
		esac
	done
	_rt="$P/lib/opencode1/runtime/opencode"
	echo "The following will be removed:"
	echo "  ✓ Package: opencode (dpkg -r)"
	if [ "$_purge" = "1" ]; then
		for _root in $_roots; do
			[ -e "$_root" ] && echo "  ✓ Data: $_root" || echo "  ○ Data: $_root (absent)"
		done
	else
		echo "  ○ User data kept (use --purge-data to remove)"
		for _root in $_roots; do
			[ -e "$_root" ] && echo "    kept: $_root"
		done
	fi
	if [ "$_dry" = "1" ]; then
		echo "Dry run — no changes made."
		exit 0
	fi
	if [ "$_force" != "1" ]; then
		[ -t 0 ] || { echo "opencode: not a terminal — re-run with --force or --dry-run" >&2; exit 1; }
		printf 'Are you sure you want to uninstall? [y/N] '
		read -r _reply < /dev/tty 2>/dev/null || _reply=""
		case "$_reply" in
			[Yy]*) ;;
			*) echo "Cancelled."; exit 0 ;;
		esac
	fi
	# Never auto-kill here: the pattern also matches whoever invoked this
	# uninstaller (including background agent sessions) — killing them would
	# strand the user mid-operation. A removed binary keeps running from its
	# deleted inode until it exits, so just warn and let the operator stop it.
	if command -v pgrep >/dev/null 2>&1; then
		_pids="$(pgrep -f "^$_rt( |$)" 2>/dev/null || true)"
		if [ -n "$_pids" ]; then
			echo "Note: opencode processes still running (PIDs: $(echo "$_pids" | tr '\n' ' '))." >&2
			echo "They keep using the removed files until they exit — stop them yourself if needed." >&2
		fi
	fi
	dpkg -r opencode < /dev/null
	if [ "$_purge" = "1" ]; then
		for _root in $_roots; do
			[ -e "$_root" ] || continue
			rm -rf "$_root"
			echo "Removed $_root"
		done
	fi
	echo "Done."
	exit 0
fi

# runtime probe order: packaged layout first, then the legacy staged layout.
for _rt in "$P/lib/opencode1/runtime/opencode" "$P/lib/opencode/runtime/opencode"; do
	if [ -x "$_rt" ]; then
		exec "$_rt" "$@"
	fi
done
echo "opencode: runtime not found under $P/lib/opencode1/runtime or $P/lib/opencode/runtime" >&2
exit 127
