#!/usr/bin/env bash
# termux-opencode installer — installs the latest (or pinned) `opencode`
# release package for Termux on Android (AArch64).
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/DARKBOYJYOTI/termux-opencode/main/install.sh | bash
#   curl -fsSL .../install.sh | bash -s -- -v 1.19.1
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
set -euo pipefail

REPO="DARKBOYJYOTI/termux-opencode"
API="https://api.github.com/repos/$REPO/releases"

usage() {
	echo "Usage: install.sh [-v <version>]   (default: latest release)"
	echo "Example: install.sh -v 1.19.1"
}

VERSION=""
while [[ $# -gt 0 ]]; do
	case "$1" in
		-h|--help) usage; exit 0 ;;
		-v|--version)
			[[ -n "${2:-}" ]] || { echo "Error: -v needs a version argument" >&2; exit 1; }
			VERSION="$2"; shift 2 ;;
		-*) echo "Error: unknown option $1" >&2; usage >&2; exit 1 ;;
		*) echo "Error: unexpected argument $1" >&2; usage >&2; exit 1 ;;
	esac
done

command -v curl >/dev/null 2>&1 || { echo "Error: curl is required (pkg install curl)" >&2; exit 1; }
command -v dpkg >/dev/null 2>&1 || { echo "Error: dpkg is required (Termux apt)" >&2; exit 1; }
case "$(uname -m)" in
	aarch64|arm64) ;;
	*) echo "Error: only AArch64 Android is supported (uname -m: $(uname -m))" >&2; exit 1 ;;
esac

echo "==> updating Termux package lists..."
pkg update
echo "==> ensuring required packages (curl, ca-certificates)..."
pkg install -y curl ca-certificates

# Drop the stale third-party apt source left by the old upstream installer:
# it serves no packages and only slows updates. Releases come only from
# this repository's GitHub releases (downloaded + checksum-verified below).
TERMUX_PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
STALE_SOURCE="$TERMUX_PREFIX/etc/apt/sources.list.d/hope2333-bootstrap.list"
if [[ -f "$STALE_SOURCE" ]]; then
	echo "==> removing stale upstream apt source (hope2333-bootstrap.list)..."
	rm -f "$STALE_SOURCE"
	pkg update
fi
if dpkg-query -W -f='${Status}' hope2333-mirrorlist 2>/dev/null | grep -q "installed"; then
	echo "==> removing broken hope2333-mirrorlist package..."
	dpkg --remove --force-remove-reinstreq hope2333-mirrorlist 2>/dev/null || true
fi

if [[ -z "$VERSION" ]]; then
	echo "==> resolving latest release..."
	TAG="$(curl -fsSL --max-time 15 "$API/latest" | grep -m1 '"tag_name"' | sed 's/.*"tag_name": *"//;s/".*//')"
	case "$TAG" in
		opencode-*) VERSION="${TAG#opencode-}" ;;
		*) echo "Error: unexpected latest tag: ${TAG:-<empty>}" >&2; exit 1 ;;
	esac
fi
[[ "$VERSION" =~ ^1\.[0-9]+\.[0-9]+$ ]] || { echo "Error: not a v1 version: $VERSION" >&2; exit 1; }

DEB="opencode_${VERSION}_aarch64.deb"
BASE_URL="https://github.com/$REPO/releases/download/opencode-$VERSION"
WORKDIR="$(mktemp -d "${TMPDIR:-/data/data/com.termux/files/usr/tmp}/termux-opencode-install.XXXXXX")"
trap 'rm -rf "$WORKDIR"' EXIT
cd "$WORKDIR"

echo "==> downloading $DEB ..."
curl -fSL --max-time 300 -o "$DEB" "$BASE_URL/$DEB"
curl -fsSL --max-time 60 -o "$DEB.sha256" "$BASE_URL/$DEB.sha256"

echo "==> verifying checksum..."
EXPECTED="$(cut -d' ' -f1 < "$DEB.sha256")"
ACTUAL="$(sha256sum "$DEB" | cut -d' ' -f1)"
if [[ "$EXPECTED" != "$ACTUAL" ]]; then
	echo "Error: SHA-256 mismatch for $DEB" >&2
	echo "  expected: $EXPECTED" >&2
	echo "  actual:   $ACTUAL" >&2
	exit 1
fi
echo "    checksum OK"

if dpkg-query -W -f='${Status}' opencode1 2>/dev/null | grep -q "ok installed"; then
	echo "==> removing legacy opencode1 package (your data stays in place)..."
	dpkg -r opencode1
fi

echo "==> installing $DEB ..."
dpkg -i "$DEB"

echo "==> verifying..."
INSTALLED="$(opencode --version)"
echo "    opencode --version = $INSTALLED"
[[ "$INSTALLED" == *"$VERSION"* ]] || { echo "Error: version mismatch after install" >&2; exit 1; }

echo "Done. Run: opencode"
