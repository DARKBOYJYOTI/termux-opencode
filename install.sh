#!/usr/bin/env bash
# termux-opencode installer — installs the latest (or pinned) `opencode`
# release package for Termux on Android (AArch64).
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/DARKBOYJYOTI/termux-opencode/main/install.sh | bash
#   curl -fsSL .../install.sh | bash -s -- -v 1.19.2
#
# What it does:
#   1. updates Termux package lists and ensures required packages
#      (curl + ca-certificates — the runtime needs them for downloads and
#      the daily release-update notice over HTTPS),
#   2. resolves the version (explicit -v, else this repo's latest release),
#   3. downloads opencode_<ver>_aarch64.deb + its SHA-256 file,
#   4. verifies the checksum (aborts on mismatch),
#   5. removes the legacy `opencode1` package if present (user data untouched),
#   6. installs via dpkg and verifies `opencode --version`.
#
# It never touches your shell config, never adds aliases, and never contacts
# the official OpenCode channel — releases come only from this repository.
#
# Pipe-safety: this script is meant to run as `curl ... | bash`, so every
# child command gets stdin from /dev/null — otherwise package tools would
# swallow the rest of the script stream and the install would stop halfway.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

REPO="DARKBOYJYOTI/termux-opencode"
API="https://api.github.com/repos/$REPO/releases"

# ── premium terminal UI (colors only on a TTY, honors NO_COLOR) ──────────
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
	C_BOLD='\033[1m'; C_DIM='\033[2m'; C_CYAN='\033[36m'
	C_GREEN='\033[32m'; C_RED='\033[31m'; C_YELLOW='\033[33m'; C_OFF='\033[0m'
else
	C_BOLD=''; C_DIM=''; C_CYAN=''; C_GREEN=''; C_RED=''; C_YELLOW=''; C_OFF=''
fi

banner() {
	printf '\n'
	printf '%b┌──────────────────────────────────────────────┐%b\n' "$C_CYAN" "$C_OFF"
	printf '%b│%b  %btermux-opencode%b  ·  native OpenCode for Termux  %b│%b\n' \
		"$C_CYAN" "$C_OFF" "$C_BOLD" "$C_OFF" "$C_CYAN" "$C_OFF"
	printf '%b└──────────────────────────────────────────────┘%b\n' "$C_CYAN" "$C_OFF"
	printf '\n'
}

step()  { printf '%b▸%b %s\n' "$C_CYAN" "$C_OFF" "$1"; }
ok()    { printf '%b✓%b %s\n' "$C_GREEN" "$C_OFF" "$1"; }
info()  { printf '  %b%s%b\n' "$C_DIM" "$1" "$C_OFF"; }
warn()  { printf '%b!%b %s\n' "$C_YELLOW" "$C_OFF" "$1"; }
die()   { printf '%b✗ Error:%b %s\n' "$C_RED" "$C_OFF" "$1" >&2; exit 1; }

success_box() {
	printf '\n'
	printf '%b┌──────────────────────────────────────────────┐%b\n' "$C_GREEN" "$C_OFF"
	printf '%b│%b  %b✓ Installed: opencode %s%b                        %b│%b\n' \
		"$C_GREEN" "$C_OFF" "$C_BOLD" "$1" "$C_GREEN" "$C_OFF"
	printf '%b│%b  Run: %bopencode%b                                   %b│%b\n' \
		"$C_GREEN" "$C_OFF" "$C_BOLD" "$C_OFF" "$C_GREEN" "$C_OFF"
	printf '%b└──────────────────────────────────────────────┘%b\n' "$C_GREEN" "$C_OFF"
	printf '\n'
}

usage() {
	echo "Usage: install.sh [-v <version>]   (default: latest release)"
	echo "Example: install.sh -v 1.19.2"
}

VERSION=""
while [[ $# -gt 0 ]]; do
	case "$1" in
		-h|--help) usage; exit 0 ;;
		-v|--version)
			[[ -n "${2:-}" ]] || die "-v needs a version argument"
			VERSION="$2"; shift 2 ;;
		-*) die "unknown option $1" ;;
		*) die "unexpected argument $1" ;;
	esac
done

banner

step "Checking environment..."
command -v curl >/dev/null 2>&1 || die "curl is required (pkg install curl)"
command -v dpkg >/dev/null 2>&1 || die "dpkg is required (Termux apt)"
case "$(uname -m)" in
	aarch64|arm64) ok "AArch64 Android" ;;
	*) die "only AArch64 Android is supported (uname -m: $(uname -m))" ;;
esac

step "Updating Termux package lists..."
pkg update < /dev/null
ok "package lists updated"

step "Ensuring required packages (curl, ca-certificates)..."
pkg install -y curl ca-certificates < /dev/null
ok "required packages present"

# Drop the stale third-party apt source left by the old upstream installer:
# it serves no packages and only slows updates. Releases come only from
# this repository's GitHub releases (downloaded + checksum-verified below).
TERMUX_PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
STALE_SOURCE="$TERMUX_PREFIX/etc/apt/sources.list.d/hope2333-bootstrap.list"
if [[ -f "$STALE_SOURCE" ]]; then
	step "Removing stale upstream apt source..."
	rm -f "$STALE_SOURCE"
	pkg update < /dev/null
	ok "stale source removed"
fi
if dpkg-query -W -f='${Status}' hope2333-mirrorlist 2>/dev/null | grep -q "installed"; then
	step "Removing broken hope2333-mirrorlist package..."
	dpkg --remove --force-remove-reinstreq hope2333-mirrorlist < /dev/null 2>/dev/null || true
	ok "stale package removed"
fi

if [[ -z "$VERSION" ]]; then
	step "Resolving latest release..."
	TAG="$(curl -fsSL --max-time 15 "$API/latest" | grep -m1 '"tag_name"' | sed 's/.*"tag_name": *"//;s/".*//')"
	case "$TAG" in
		opencode-*) VERSION="${TAG#opencode-}" ;;
		*) die "unexpected latest tag: ${TAG:-<empty>}" ;;
	esac
fi
[[ "$VERSION" =~ ^1\.[0-9]+\.[0-9]+$ ]] || die "not a v1 version: $VERSION"
ok "version: $VERSION"

DEB="opencode_${VERSION}_aarch64.deb"
BASE_URL="https://github.com/$REPO/releases/download/opencode-$VERSION"
WORKDIR="$(mktemp -d "${TMPDIR:-/data/data/com.termux/files/usr/tmp}/termux-opencode-install.XXXXXX")"
trap 'rm -rf "$WORKDIR"' EXIT
cd "$WORKDIR"

step "Downloading $DEB..."
info "$BASE_URL/$DEB"
curl -fSL --max-time 300 -o "$DEB" "$BASE_URL/$DEB" < /dev/null
curl -fsSL --max-time 60 -o "$DEB.sha256" "$BASE_URL/$DEB.sha256" < /dev/null
ok "download complete"

step "Verifying checksum..."
EXPECTED="$(cut -d' ' -f1 < "$DEB.sha256")"
ACTUAL="$(sha256sum "$DEB" | cut -d' ' -f1)"
[[ "$EXPECTED" == "$ACTUAL" ]] || {
	echo "  expected: $EXPECTED" >&2
	echo "  actual:   $ACTUAL" >&2
	die "SHA-256 mismatch for $DEB"
}
ok "checksum OK"

if dpkg-query -W -f='${Status}' opencode1 2>/dev/null | grep -q "ok installed"; then
	step "Removing legacy opencode1 package (your data stays in place)..."
	dpkg -r opencode1 < /dev/null
	ok "legacy package removed"
fi

step "Installing $DEB..."
dpkg -i "$DEB" < /dev/null
ok "package installed"

step "Verifying installation..."
INSTALLED="$(opencode --version < /dev/null)"
info "opencode --version = $INSTALLED"
[[ "$INSTALLED" == *"$VERSION"* ]] || die "version mismatch after install"
ok "verified"

success_box "$VERSION"
