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

Upstream minifier identifiers are not stable across releases, so anchors are
grouped per known upstream build ("anchor sets"). Exactly one set must match a
given binary; an unknown layout fails closed. When an upstream bump renames
identifiers, add a new set after verifying each byte sequence occurs once.

Each set patches six sites (all same-length):

  1. flag default (source of truth the check reads):
       OPENCODE_DISABLE_AUTOUPDATE:<reader>("OPENCODE_DISABLE_AUTOUPDATE")
     -> OPENCODE_DISABLE_AUTOUPDATE:!0<pad>
  2. the auto-check gate inside the async update-check function:
       if(<flag>.autoupdate===!1||<env>.OPENCODE_DISABLE_AUTOUPDATE)return;
     -> if(!0<pad>)return;
  3. the TUI palette entry that registers the `/update` command (it opens the
     update dialog, whose component calls updater.check() on mount):
       <open>.open?[{name:"opencode.update"
     -> void 0?[{name:"opencode.update"
  4. the guard in Installation.upgrade: forced true so ANY in-process official
     install (dialog apply(), POST /global/upgrade, runtime CLI upgrade) throws
     before touching the network or the filesystem:
       if(<schema>.default.valid(<target>)&&<schema>.default.major(<target>)>=2)
     -> if(!0<pad>)
  5. the server route path for POST /global/upgrade: pointed at a non-existent
     path so a direct API call 404s:
       dispose:"/global/dispose",upgrade:"/global/upgrade"
     -> dispose:"/global/dispose",upgrade:"/global/upgradX"
  6. the updater wrapper's check(): stops the official version fetch outright:
       await <svc>.latest(await <svc>.method()).catch(()=>{return})
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

# (old, new) pairs per upstream build; len(new) MUST equal len(old).
# Newest set last (used for diagnostics and as the ANCHORS alias).
ANCHOR_SETS = [
    (
        "1.19.3",
        [
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
        ],
    ),
    (
        "1.19.5",
        [
            (
                b'OPENCODE_DISABLE_AUTOUPDATE:mc("OPENCODE_DISABLE_AUTOUPDATE")',
                b"OPENCODE_DISABLE_AUTOUPDATE:!0" + PAD(31),
            ),
            (
                b"if(e.autoupdate===!1||_e.OPENCODE_DISABLE_AUTOUPDATE)return;",
                b"if(!0" + PAD(47) + b")return;",
            ),
            (
                b'J.open?[{name:"opencode.update"',
                b'void 0?[{name:"opencode.update"',
            ),
            (
                b"if(u.default.valid(e)&&u.default.major(e)>=2)",
                b"if(!0" + PAD(39) + b")",
            ),
            (
                b'dispose:"/global/dispose",upgrade:"/global/upgrade"',
                b'dispose:"/global/dispose",upgrade:"/global/upgradX"',
            ),
            (
                b"await i.latest(await i.method()).catch(()=>{return})",
                b"await Promise.resolve()" + PAD(29),
            ),
        ],
    ),
]

ANCHORS = ANCHOR_SETS[-1][1]

TRAILER = b"\n---- Bun! ----\n"


def die(msg: str) -> NoReturn:
    print(f"strip_official_update: ERROR: {msg}", file=sys.stderr)
    sys.exit(1)


def _set_progress(data: bytes, anchors: list[tuple[bytes, bytes]]):
    """Classify each anchor as pristine, patched, or invalid for this set."""
    pristine: list[tuple[bytes, bytes]] = []
    patched: list[tuple[bytes, bytes]] = []
    bad: list[tuple[bytes, int, int]] = []
    for old, new in anchors:
        if len(old) != len(new):
            die(f"internal: anchor length mismatch ({len(old)} != {len(new)}): {old!r}")
        if old == new:
            die(f"internal: no-op anchor {old!r}")
        n_old, n_new = data.count(old), data.count(new)
        if n_old == 1 and n_new == 0:
            pristine.append((old, new))
        elif n_old == 0 and n_new == 1:
            patched.append((old, new))
        else:
            bad.append((old, n_old, n_new))
    return pristine, patched, bad


def _no_match_error(data: bytes) -> str:
    """Explain the newest set's shape drift (message contains 'anchor occurs')."""
    name, anchors = ANCHOR_SETS[-1]
    for old, new in anchors:
        n_old, n_new = data.count(old), data.count(new)
        if not ((n_old == 1 and n_new == 0) or (n_old == 0 and n_new == 1)):
            return (
                f"anchor occurs {n_old} time(s), expected exactly 1 "
                f"(set {name}): {old.decode()!r}"
            )
    return f"no known anchor set matched (newest set {name})"


def transform(data: bytes) -> tuple[bytes, bool]:
    """Return (patched_bytes, changed). Raises ValueError on shape drift.

    Idempotent per anchor: an anchor already in its patched form is skipped, so
    a partially-applied binary (e.g. a re-run over an older build) is fine.
    Exactly one known anchor set must match; an unknown layout fails closed.
    """
    matches = []
    for name, anchors in ANCHOR_SETS:
        pristine, patched, bad = _set_progress(data, anchors)
        if not bad:
            matches.append((name, pristine, patched))

    if not matches:
        raise ValueError(_no_match_error(data))
    if len(matches) > 1:
        names = ", ".join(name for name, _p, _q in matches)
        raise ValueError(f"ambiguous anchor set match: {names}")

    _name, pristine, _patched = matches[0]
    if not pristine:
        return data, False

    out = bytearray(data)
    allowed: set[int] = set()
    for old, new in pristine:
        at = data.find(old)
        out[at : at + len(old)] = new
        allowed.update(range(at, at + len(old)))

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


def verify(data: bytes) -> str:
    """Return the matching anchor-set name; raise ValueError unless stripped."""
    fully_patched = []
    for name, anchors in ANCHOR_SETS:
        pristine, patched, bad = _set_progress(data, anchors)
        if not bad and not pristine and patched:
            fully_patched.append(name)

    if len(fully_patched) == 1:
        return fully_patched[0]
    if len(fully_patched) > 1:
        raise ValueError(f"ambiguous fully stripped anchor sets: {', '.join(fully_patched)}")

    for name, anchors in ANCHOR_SETS:
        for old, _new in anchors:
            if data.count(old):
                raise ValueError(
                    f"official update anchor still present (set {name}): "
                    f"{old.decode()!r}"
                )
    raise ValueError("no fully stripped known anchor set found")


def selftest() -> int:
    """Deterministic check of transform() on a synthetic buffer."""
    filler = bytes(range(256)) * 4

    # Every known set must patch, verify, and stay idempotent.
    for set_name, set_anchors in ANCHOR_SETS:
        blob = bytearray(b"\x7fELF\x02\x01\x01\x00" + filler)
        for old, _ in set_anchors:
            blob += b"\x00" + old + b"\x00"
        blob += filler
        pristine = bytes(blob) + TRAILER

        patched, changed = transform(pristine)
        assert changed is True, f"{set_name}: pristine not patched"
        assert len(patched) == len(pristine), f"{set_name}: size changed"
        for old, new in set_anchors:
            assert patched.count(old) == 0, f"{set_name}: old anchor survives: {old!r}"
            assert patched.count(new) == 1, f"{set_name}: new marker missing: {new!r}"
        assert verify(patched) == set_name, f"{set_name}: verify mismatch"

        again, changed2 = transform(patched)
        assert changed2 is False and again == patched, f"{set_name}: not idempotent"

        try:
            verify(pristine)
        except ValueError:
            pass
        else:
            raise AssertionError(f"{set_name}: pristine passed verify")

    # Partial application: patch only anchors[0], then the rest must apply.
    filler = bytes(range(256)) * 4
    blob = bytearray(b"\x7fELF\x02\x01\x01\x00" + filler)
    for old, _ in ANCHORS:
        blob += b"\x00" + old + b"\x00"
    blob += filler
    pristine = bytes(blob) + TRAILER
    patched, _ = transform(pristine)

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
    if len(sys.argv) == 3 and sys.argv[1] == "--verify":
        path = sys.argv[2]
        with open(path, "rb") as f:
            data = f.read()
        try:
            name = verify(data)
        except ValueError as e:
            die(str(e))
        print(f"strip_official_update: verified {path} (anchor set {name})")
        return
    if len(sys.argv) != 2:
        die(f"usage: {sys.argv[0]} [--verify] <native-elf>")
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
