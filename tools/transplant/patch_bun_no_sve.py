#!/usr/bin/env python3
"""Disable every Highway SVE target in the pinned Bun Android source build.

The official Android Bun 1.4.4 binary selects SVE code on this non-SVE device.
For the source-built replacement base, retain Highway's normal NEON dispatch
but exclude SVE, SVE2, SVE_256, and SVE2_128 at compile time. Fail closed if
the pinned source layout or commit changes.
"""

import subprocess
import sys
from pathlib import Path


EXPECTED_COMMIT_PREFIX = "38afee6c8"
CONFIG = Path("scripts/build/deps/highway.ts")
OLD = 'const disabledTargets = "HWY_DISABLED_TARGETS=HWY_ALL_SVE-HWY_SVE2_128";'
NEW = 'const disabledTargets = "HWY_DISABLED_TARGETS=HWY_ALL_SVE";'


def main() -> int:
    if len(sys.argv) != 2:
        print(f"usage: {Path(sys.argv[0]).name} <bun-source-checkout>", file=sys.stderr)
        return 2

    root = Path(sys.argv[1]).resolve()
    source = root / CONFIG
    if not source.is_file():
        print(f"missing Bun source file: {source}", file=sys.stderr)
        return 1

    try:
        commit = subprocess.check_output(
            ["git", "-C", str(root), "rev-parse", "HEAD"], text=True
        ).strip()
    except (OSError, subprocess.CalledProcessError) as exc:
        print(f"cannot verify Bun source revision: {exc}", file=sys.stderr)
        return 1
    if not commit.startswith(EXPECTED_COMMIT_PREFIX):
        print(
            f"unexpected Bun source revision {commit}; expected {EXPECTED_COMMIT_PREFIX}*",
            file=sys.stderr,
        )
        return 1

    text = source.read_text(encoding="utf-8")
    hits = text.count(OLD)
    if hits != 1:
        print(
            f"expected exactly one Highway SVE2_128 target declaration, found {hits}",
            file=sys.stderr,
        )
        return 1
    if "defines: [disabledTargets]" not in text:
        print("Highway target define is not propagated to Bun translation units", file=sys.stderr)
        return 1

    source.write_text(text.replace(OLD, NEW, 1), encoding="utf-8")
    print(f"Bun {commit[:10]}: disabled Highway SVE targets for Android build")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
