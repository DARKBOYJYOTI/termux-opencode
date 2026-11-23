#!/bin/sh
# tests/run.sh — run the shell unit test suite with bats.
#
# Usage:
#   tests/run.sh                 # run every *.bats file under tests/unit
#   tests/run.sh tests/unit/common.bats   # run specific file(s)
# Termux has no /usr/bin/env, so re-exec under bash from this sh shebang.
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BATS_BIN="$(bash "$TESTS_DIR/bootstrap.sh")"

if [[ $# -gt 0 ]]; then
	exec bash "$BATS_BIN" "$@"
fi

exec bash "$BATS_BIN" --recursive "$TESTS_DIR/unit"
