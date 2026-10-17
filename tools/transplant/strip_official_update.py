#!/usr/bin/env python3
"""Strip the official update channel from a transplanted native ELF.

Policy (AGENTS.md section 5): packages from this repository are the ONLY
supported upgrade path. The launcher already exports
OPENCODE_DISABLE_AUTOUPDATE=1, but that is a runtime default a user (or a
direct `runtime/opencode` invocation) could unset. This build-time patch makes
the official update channel structurally impossible inside the shipped
runtime, independent of environment.

The runtime is a Bun standalone binary: the JS module graph is embedded as
PLAINTEXT, so a set of same-length, in-place edits is enough — no offset,
module header, or loader metadata is disturbed. Every anchor must occur
EXACTLY once (fail closed otherwise — an upstream bump that moved one must
stop the build, not silently ship an official update path), and every edit is
idempotent per anchor.

Anchors (all same-length):

  1. flag default (source of truth the check reads):
       OPENCODE_DISABLE_AUTOUPDATE:j("OPENCODE_DISABLE_AUTOUPDATE")
     -> OPENCODE_DISABLE_AUTOUPDATE:!0<pad>
  2. the auto-check gate inside the async update-check function:
       if(j.autoupdate===!1||K.OPENCODE_DISABLE_AUTOUPDATE)return;
     -> if(!0<pad>)return;
  3. the TUI palette entry that registers the `/update` command (it opens the
     update dialog, whose component calls updater.check() on mount):
       m.open?[{name:"opencode.update"
     -> void 0?[{name:"opencode.update"
  4. the guard in Installation.upgrade: forced true so ANY in-process official
     install (dialog apply(), POST /global/upgrade, runtime CLI upgrade) throws
     before touching the network or the filesystem:
       if($.default.valid(D)&&$.default.major(D)>=2)
     -> if(!0<pad>)
  5. the server route path for POST /global/upgrade: pointed at a non-existent
     path so a direct API call 404s:
       dispose:"/global/dispose",upgrade:"/global/upgrade"
     -> dispose:"/global/dispose",upgrade:"/global/upgradX"
  6. the updater wrapper's check(): stops the official version fetch outright:
       await E.latest(await E.method()).catch(()=>{return})
     -> await Promise.resolve()<pad>

With these, the TUI never learns an update exists (no /update command, no
notice, no dialog), and no in-process path can install an official build. The
repository's own notice (launcher) and `opencode upgrade` (served by the
shipped installer) are the only update surface.

The edit proves zero displacement: the file size is unchanged and every byte
outside the anchors is identical.
"""
import hashlib
import sys
from typing import NoReturn

PAD = lambda n: b" " * n  # noqa: E731 (small local helper)

# (old, new) pairs; len(new) MUST equal len(old).
ANCHORS = [
    (
        b'OPENCODE_DISABLE_AUTOUPDATE:j("OPENCODE_DISABLE_AUTOUPDATE")',
        b"OPENCODE_DISABLE_AUTOUPDATE:!0" + PAD(30),
    ),
    (
        b"if(j.autoupdate===!1||K.OPENCODE_DISABLE_AUTOUPDATE)return;",
        b"if(!0" + PAD(46) + b")return;",
    ),
    (
        b'm.open?[{name:"opencode.update"',
        b'void 0?[{name:"opencode.update"',
    ),
    (
        b"if($.default.valid(D)&&$.default.major(D)>=2)",
        b"if(!0" + PAD(39) + b")",
    ),
    (
        b'dispose:"/global/dispose",upgrade:"/global/upgrade"',
        b'dispose:"/global/dispose",upgrade:"/global/upgradX"',
    ),
    (
        b"await E.latest(await E.method()).catch(()=>{return})",
        b"await Promise.resolve()" + PAD(29),
    ),
]

TRAILER = b"\n---- Bun! ----\n"


def die(msg: str) -> NoReturn:
    print(f"strip_official_update: ERROR: {msg}", file=sys.stderr)
    sys.exit(1)


def transform(data: bytes) -> tuple[bytes, bool]:
    """Return (patched_bytes, changed). Raises ValueError on shape drift.

    Idempotent per anchor: an anchor already in its patched form is skipped, so
    a partially-applied binary (e.g. a re-run over an older build) is fine.
    """
    for old, new in ANCHORS:
        if len(old) != len(new):
            die(f"internal: anchor length mismatch ({len(old)} != {len(new)}): {old!r}")

    out = bytearray(data)
    allowed: set[int] = set()
    applied = 0
    for old, new in ANCHORS:
        n_old, n_new = data.count(old), data.count(new)
        if old == new:
            die(f"internal: no-op anchor {old!r}")
        if n_old == 0 and n_new == 1:
            continue  # already applied
        if n_old != 1:
            raise ValueError(
                f"anchor occurs {n_old} time(s), expected exactly 1: {old.decode()!r}"
            )
        if n_new != 0:
            raise ValueError(f"patched marker already present: {new.decode()!r}")
        at = data.find(old)
        out[at : at + len(old)] = new
        allowed.update(range(at, at + len(old)))
        applied += 1

    if applied == 0:
        return data, False

    # Proof: nothing outside the anchors moved.
    if len(out) != len(data):
        raise ValueError(f"file size changed {len(data)} -> {len(out)}")
    if data[:4] != b"\x7fELF" or bytes(out[:4]) != b"\x7fELF":
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
    pristine = bytes(blob) + TRAILER

    patched, changed = transform(pristine)
    assert changed is True, "pristine not patched"
    assert len(patched) == len(pristine), "size changed"
    for old, new in ANCHORS:
        assert patched.count(old) == 0, f"old anchor survives: {old!r}"
        assert patched.count(new) == 1, f"new marker missing: {new!r}"

    again, changed2 = transform(patched)
    assert changed2 is False and again == patched, "not idempotent"

    # Partial application: patch only anchors[0], then the rest must apply.
    old0, new0 = ANCHORS[0]
    partial = pristine.replace(old0, new0, 1)
    done, changed3 = transform(partial)
    assert changed3 is True and done == patched, "partial apply mismatch"

    # A duplicated anchor must fail closed.
    bad = pristine.replace(ANCHORS[0][0], ANCHORS[0][0] + ANCHORS[0][0], 1)
    try:
        transform(bad)
    except ValueError:
        pass
    else:
        raise AssertionError("duplicate anchor did not fail closed")

    # A missing anchor (upstream drift) must fail closed.
    drift = pristine.replace(ANCHORS[2][0], b"X" * len(ANCHORS[2][0]), 1)
    try:
        transform(drift)
    except ValueError:
        pass
    else:
        raise AssertionError("missing anchor did not fail closed")

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
        f"(official update channel disabled; sha256:{digest}…) "
        "— repo installer is the only upgrade path"
    )


if __name__ == "__main__":
    main()
