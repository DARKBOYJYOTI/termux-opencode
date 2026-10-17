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

# Build a synthetic "runtime" carrying every configured anchor, using the
# module's own ANCHORS list so the test never drifts from the patcher.
make_synthetic() {
	python3 - "$SCRIPT" "$1" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("sou", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
body = b"\x7fELF\x02\x01\x01\x00" + bytes(range(256))
body += b"".join(b"\x00" + old + b"\x00" for old, _ in mod.ANCHORS)
body += b"\n---- Bun! ----\n"
open(sys.argv[2], "wb").write(body)
PY
}

@test "selftest passes" {
	run python3 "$SCRIPT" --selftest
	[ "$status" -eq 0 ]
	[[ "$output" == *"selftest OK"* ]]
}

@test "strips every anchor and is idempotent" {
	BIN="$TEST_TMPDIR/runtime"
	make_synthetic "$BIN"

	run python3 "$SCRIPT" "$BIN"
	[ "$status" -eq 0 ]
	[[ "$output" == *"disabled"* ]]

	# No original anchor may survive; every patched marker must be present.
	python3 - "$SCRIPT" "$BIN" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("sou", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
d = open(sys.argv[2], "rb").read()
for old, new in mod.ANCHORS:
    assert d.count(old) == 0, f"old anchor survived: {old!r}"
    assert d.count(new) == 1, f"new marker missing: {new!r}"
PY
	[ "$?" -eq 0 ]

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
