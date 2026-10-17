#!/usr/bin/env python3
"""Strip the official update channel from a transplanted native ELF.

Policy (AGENTS.md section 5): packages from this repository are the ONLY
supported upgrade path. The launcher already exports
OPENCODE_DISABLE_AUTOUPDATE=1, but that is a runtime default a user (or a
direct `runtime/opencode` invocation) could unset. This build-time patch makes
official update detection structurally impossible inside the shipped runtime,
independent of environment.

The runtime is a Bun standalone binary: the JS module graph is embedded as
PLAINTEXT, so two same-length, in-place edits are enough — no offset, module
header, or loader metadata is disturbed:

  1. flag default (the source of truth the check reads):
       OPENCODE_DISABLE_AUTOUPDATE:j("OPENCODE_DISABLE_AUTOUPDATE")
     -> OPENCODE_DISABLE_AUTOUPDATE:!0<pad>
  2. the detection gate inside the async update-check function:
       if(j.autoupdate===!1||K.OPENCODE_DISABLE_AUTOUPDATE)return;
     -> if(!0<pad>)return;

Both anchors must occur EXACTLY once (fail closed otherwise — an upstream
bump that moved them must stop the build, not silently ship an official
update channel). The edit is idempotent and proves zero displacement: the
file size is unchanged and every byte outside the two anchors is identical.

With detection short-circuited the TUI never learns an update exists, so the
`/update` palette command, the footer notice and the update dialog are all
unreachable; the repository's own notice (launcher) and `opencode upgrade`
(served by the shipped installer) are the only update surface.
"""
import hashlib
import sys
from typing import NoReturn

# (old, new) pairs; len(new) MUST equal len(old).
PAD = lambda n: b" " * n  # noqa: E731 (small local helper)
ANCHORS = [
    (
        b'OPENCODE_DISABLE_AUTOUPDATE:j("OPENCODE_DISABLE_AUTOUPDATE")',
        b"OPENCODE_DISABLE_AUTOUPDATE:!0" + PAD(30),
    ),
    (
        b"if(j.autoupdate===!1||K.OPENCODE_DISABLE_AUTOUPDATE)return;",
        b"if(!0" + PAD(46) + b")return;",
    ),
]

TRAILER = b"\n---- Bun! ----\n"


def die(msg: str) -> NoReturn:
    print(f"strip_official_update: ERROR: {msg}", file=sys.stderr)
    sys.exit(1)


def transform(data: bytes) -> tuple[bytes, bool]:
    """Return (patched_bytes, changed). Raises ValueError on shape drift."""
    for old, new in ANCHORS:
        if len(old) != len(new):
            die(f"internal: anchor length mismatch ({len(old)} != {len(new)})")

    already = all(data.count(old) == 0 and data.count(new) == 1 for old, new in ANCHORS)
    if already:
        return data, False

    out = bytearray(data)
    allowed: set[int] = set()
    for old, new in ANCHORS:
        n = data.count(old)
        if n != 1:
            raise ValueError(
                f"anchor occurs {n} time(s), expected exactly 1: {old.decode()!r}"
            )
        if data.count(new) != 0:
            raise ValueError(f"patched marker already present: {new.decode()!r}")
        at = data.find(old)
        out[at : at + len(old)] = new
        allowed.update(range(at, at + len(old)))

    # Proof: nothing outside the anchors moved.
    if len(out) != len(data):
        raise ValueError(f"file size changed {len(data)} -> {len(out)}")
    if data[:4] != b"\x7fELF" or out[:4] != b"\x7fELF":
        raise ValueError("ELF magic not preserved")
    diffs = [i for i, (a, b) in enumerate(zip(data, out)) if a != b]
    stray = [i for i in diffs if i not in allowed]
    if stray:
        raise ValueError(f"{len(stray)} byte(s) changed outside the anchors")
    if TRAILER not in data or TRAILER not in bytes(out):
        raise ValueError("standalone Bun trailer not preserved")
    return bytes(out), True


def selftest() -> int:
    """Deterministic check of transform() on a synthetic buffer."""
    filler = bytes(range(256)) * 4
    blob = bytearray(b"\x7fELF\x02\x01\x01\x00" + filler)
    for old, _ in ANCHORS:
        blob += b"\x00" + old + b"\x00"
    blob += filler
    data = bytes(blob) + TRAILER

    patched, changed = transform(data)
    assert changed is True
    assert len(patched) == len(data)
    for old, new in ANCHORS:
        assert patched.count(old) == 0
        assert patched.count(new) == 1

    again, changed2 = transform(patched)
    assert changed2 is False and again == patched, "not idempotent"

    # A truncated/duplicated anchor must fail closed.
    bad = data.replace(ANCHORS[0][0], ANCHORS[0][0] + ANCHORS[0][0], 1)
    try:
        transform(bad)
    except ValueError:
        pass
    else:
        raise AssertionError("duplicate anchor did not fail closed")

    print("strip_official_update: selftest OK")
    return 0


def main() -> None:
    if len(sys.argv) == 2 and sys.argv[1] == "--selftest":
        sys.exit(selftest())
    if len(sys.argv) != 2:
        die(f"usage: {sys.argv[0]} <native-elf>")
    path = sys.argv[1]
    with open(path, "rb") as f:
        data = f.read()

    try:
        out, changed = transform(data)
    except ValueError as e:
        die(str(e))

    if not changed:
        print(f"strip_official_update: already stripped, skip: {path}")
        return
    with open(path, "wb") as f:
        f.write(out)
    digest = hashlib.sha256(out).hexdigest()[:16]
    print(
        f"strip_official_update: OK {path} "
        f"(official update detection disabled; sha256:{digest}…) "
        "— repo installer is the only upgrade path"
    )


if __name__ == "__main__":
    main()
