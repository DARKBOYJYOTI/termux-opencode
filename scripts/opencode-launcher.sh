#!/data/data/com.termux/files/usr/bin/bash
# opencode launcher — termux-opencode build (v2 runtime, plain `opencode` name).
#
# Data layout is the OFFICIAL opencode structure: the v2 runtime reads the
# plain XDG roots (`<root>/opencode`), exactly like upstream. This launcher
# sets no XDG re-rooting — every integration (plugins, MCP, scripts) works
# with unpatched official paths.
#
# The runtime binary lives under lib/opencode2/runtime/ (internal layout kept
# from the dual-runtime era); the shipped installer under lib/opencode2/.
set -euo pipefail
P="${PREFIX:-/data/data/com.termux/files/usr}"
RT="$P/lib/opencode2/runtime/opencode"
# Keep GitHub CLI authentication reachable for wrapped gh invocations.
export GH_CONFIG_DIR="${GH_CONFIG_DIR:-$HOME/.config/gh}"
# Update-channel policy: packages from this repository are the only supported
# upgrade path. Disable the official-channel update checks and notices by
# default (upstream flag: OPENCODE_DISABLE_AUTOUPDATE, truthy = "1"/"true");
# upgrade/update/uninstall subcommands are intercepted below and served by
# this repository's installer).
export OPENCODE_DISABLE_AUTOUPDATE="${OPENCODE_DISABLE_AUTOUPDATE:-1}"
# v1 builds needed these for their DT_RUNPATH/shim and seccomp handler; the v2
# runtime links only bionic system libraries and embeds its TUI library, so
# inherited v1 values would only shadow the wrong libraries.
unset LD_PRELOAD LD_LIBRARY_PATH 2>/dev/null || true

[[ -x "$RT" ]] || {
	echo "opencode: runtime not found at $RT" >&2
	exit 127
}

# Default keybind parity with v1: Tab cycles the agent (plan/build). v2
# upstream binds agent.cycle to shift+tab; CLI settings merge, so inject the
# default through OPENCODE_CLI_CONFIG_CONTENT unless the user already chose an
# agent.cycle binding (cli.json/cli.jsonc) or set their own CLI config content.
_cli_dir="${XDG_CONFIG_HOME:-$HOME/.config}/opencode"
_cli_has_agent_cycle=0
for _f in "$_cli_dir/cli.json" "$_cli_dir/cli.jsonc"; do
	[ -f "$_f" ] || continue
	if grep -q '"agent\.cycle"' "$_f" 2>/dev/null; then
		_cli_has_agent_cycle=1
		break
	fi
done
if [ -z "${OPENCODE_CLI_CONFIG_CONTENT:-}" ] && [ "$_cli_has_agent_cycle" = "0" ]; then
	export OPENCODE_CLI_CONFIG_CONTENT='{"keybinds":{"agent.cycle":"tab"}}'
fi
unset _cli_dir _cli_has_agent_cycle _f

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
	_cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/opencode"
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

# The subcommand is the first non-flag argument (v2 accepts global flags before
# the subcommand, e.g. `opencode --auto upgrade`), so scan instead of looking
# at $1 only. The packaged runtime also has these subcommands renamed away, but
# the launcher stays the first line of defence.
_subcommand() {
	for _arg in "$@"; do
		case "$_arg" in
			--) return 0 ;;
			-*) continue ;;
			*) printf '%s' "$_arg"; return 0 ;;
		esac
	done
	return 0
}
_cmd="$(_subcommand "$@")"

# `opencode upgrade` serves this repository's releases — never the upstream
# flow (which would overwrite this hardened runtime with an official build).
# `opencode upgrade [version]` reuses the shipped installer; everything else
# passes through to the runtime untouched.
if [ "$_cmd" = "upgrade" ] || [ "$_cmd" = "update" ]; then
	_installer="$P/lib/opencode2/install.sh"
	if [ ! -f "$_installer" ]; then
		echo "opencode: upgrade handler missing ($_installer not shipped)" >&2
		exit 1
	fi
	_rest=()
	_seen=0
	for _arg in "$@"; do
		if [ "$_seen" = "0" ] && [ "$_arg" = "$_cmd" ]; then
			_seen=1
			continue
		fi
		_rest+=("$_arg")
	done
	_args=()
	for _arg in ${_rest[@]+"${_rest[@]}"}; do
		case "$_arg" in
			-r|--reinstall) _args+=("$_arg") ;;
			-h|--help) exec bash "$_installer" --help < /dev/null ;;
			-*) echo "opencode: ignoring runtime flag for upgrade: $_arg" >&2 ;;
			*) _args+=(-v "$_arg") ;;
		esac
	done
	exec bash "$_installer" ${_args[@]+"${_args[@]}"} < /dev/null
fi

# `opencode uninstall` removes exactly what this repository installed — never
# the upstream flow (which deletes data dirs by default), never anything
# else. Default keeps all user data; `--purge-data` removes the four official
# data roots after confirmation (or `--force`). `--dry-run` only prints.
if [ "$_cmd" = "uninstall" ]; then
	_rest=()
	_seen=0
	for _arg in "$@"; do
		if [ "$_seen" = "0" ] && [ "$_arg" = "$_cmd" ]; then
			_seen=1
			continue
		fi
		_rest+=("$_arg")
	done
	_purge=0; _force=0; _dry=0
	for _arg in ${_rest[@]+"${_rest[@]}"}; do
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
	_roots="${XDG_CONFIG_HOME:-$_home/.config}/opencode
${XDG_DATA_HOME:-$_home/.local/share}/opencode
${XDG_CACHE_HOME:-$_home/.cache}/opencode
${XDG_STATE_HOME:-$_home/.local/state}/opencode"
	# Paranoia guard: every purge target must be an `opencode` dir under $HOME.
	for _root in $_roots; do
		case "$_root" in
			"$_home"/*opencode*) ;;
			*) echo "opencode: refusing to touch unexpected path: $_root" >&2; exit 1 ;;
		esac
	done
	echo "The following will be removed:"
	echo "  ✓ Package: opencode (dpkg -r)"
	if [ "$_purge" = "1" ]; then
		for _root in $_roots; do
			[ -e "$_root" ] && echo "  ✓ Data: $_root" || echo "  ○ Data: $_root (absent)"
		done
	else
		echo "  ○ User data kept (use --purge-data to remove)"
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
		_pids="$(pgrep -f "^$RT( |$)" 2>/dev/null || true)"
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

exec "$RT" "$@"
