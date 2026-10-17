#!/usr/bin/env bats
# Unit tests for tools/transplant/strip_official_update.py

load '../lib/helper'

setup() {
	make_tmpdir
	SCRIPT="$(script_path tools/transplant/strip_official_update.py)"
}

teardown() {
	clean_tmpdir
}

@test "selftest passes" {
	run python3 "$SCRIPT" --selftest
	[ "$status" -eq 0 ]
	[[ "$output" == *"selftest OK"* ]]
}

@test "patches a synthetic runtime and is idempotent" {
	BIN="$TEST_TMPDIR/runtime"
	python3 - "$BIN" <<'PY'
import sys
anchors = [
    b'OPENCODE_DISABLE_AUTOUPDATE:j("OPENCODE_DISABLE_AUTOUPDATE")',
    b'if(j.autoupdate===!1||K.OPENCODE_DISABLE_AUTOUPDATE)return;',
]
data = (
    b"\x7fELF\x02\x01\x01\x00"
    + b"".join(b"\x00" + a + b"\x00" for a in anchors)
    + b"\n---- Bun! ----\n"
)
open(sys.argv[1], "wb").write(data)
PY
	run python3 "$SCRIPT" "$BIN"
	[ "$status" -eq 0 ]
	[[ "$output" == *"disabled"* ]]
	run grep -aqF 'OPENCODE_DISABLE_AUTOUPDATE:j(' "$BIN"
	[ "$status" -ne 0 ]

	run python3 "$SCRIPT" "$BIN"
	[ "$status" -eq 0 ]
	[[ "$output" == *"already stripped"* ]]
}

@test "fails closed when an anchor is missing" {
	BIN="$TEST_TMPDIR/broken"
	printf '\x7fELF\x02\x01\x01\x00 no anchors here \n---- Bun! ----\n' >"$BIN"
	run python3 "$SCRIPT" "$BIN"
	[ "$status" -eq 1 ]
	[[ "$output" == *"anchor occurs"* ]]
}
