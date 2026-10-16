# termux-opencode

[![opencode native build](https://github.com/DARKBOYJYOTI/termux-opencode/actions/workflows/build-opencode-native.yml/badge.svg?branch=main)](https://github.com/DARKBOYJYOTI/termux-opencode/actions/workflows/build-opencode-native.yml)
[![Unit Tests](https://github.com/DARKBOYJYOTI/termux-opencode/actions/workflows/tests.yml/badge.svg?branch=main)](https://github.com/DARKBOYJYOTI/termux-opencode/actions/workflows/tests.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-3fb950?style=flat-square)](./LICENSE)
[![Termux: AArch64](https://img.shields.io/badge/Termux-AArch64-1f6feb?style=flat-square)](https://termux.dev)
[![Runtime: Bionic](https://img.shields.io/badge/Runtime-Bionic-9e6a03?style=flat-square)](#how-it-works)

Native [OpenCode](https://opencode.ai) v1 (`opencode`) packages for **Termux on
Android (AArch64)**. Pure Bionic runtime, zero glibc dependencies, full TUI —
built reproducibly and verified on a real device.

The command is the plain `opencode` name, so every plugin, MCP setup, and
script works without patching. (The legacy `opencode1` packages are replaced
on install; user data is preserved.)

> **Update-channel policy:** this repository is the only supported upgrade
> path. Official-channel update checks and notices are disabled in the shipped
> launcher (`OPENCODE_DISABLE_AUTOUPDATE=1`), and the launcher notifies you
> about **this repository's releases** instead (see below). Never run the
> official installer over these packages — install the next release from here.

## Status

| Item | State |
| --- | --- |
| Current package | `opencode` **1.19.1** (`aarch64` `.deb`) |
| Runtime | Transplanted native Bionic ELF + `libopencode-crhandler.so` seccomp shim + Bionic `libopentui.so` |
| Verified on | Termux on Android 12 (API 31), kernel 4.14 — `--version`, TUI startup |
| CI | Manual-dispatch workflow builds, hardens, packages, and regression-tests every release |

## Requirements

- Android API level 28+ (Android 9.0+), AArch64 device
- [Termux](https://termux.dev) (F-Droid or GitHub release)
- ~1 GB free storage for the install (~200 MB runtime + data)
- For local builds: `make`, `python3`, `clang`, `git`, network access to npm and GitHub

## Install

One line — updates Termux lists, ensures required packages (`curl`,
`ca-certificates`), installs the latest release (checksum-verified, legacy
`opencode1` replaced automatically, stale upstream apt source dropped, user
data preserved):

```bash
curl -fsSL https://raw.githubusercontent.com/DARKBOYJYOTI/termux-opencode/main/install.sh | bash
```

Pin a version instead:

```bash
curl -fsSL https://raw.githubusercontent.com/DARKBOYJYOTI/termux-opencode/main/install.sh | bash -s -- -v 1.19.1
```

Then verify and launch:

```bash
opencode --version   # must print the installed version
opencode             # start the TUI
```

Data lives in the official plain layout (`~/.config/opencode`,
`~/.local/share/opencode`, …) — exactly like upstream, so every plugin, MCP
setup, and script works unpatched. If legacy nested `opencode1/` data exists
from older builds, it is moved back once, non-destructively (conflicting
plain dirs are backed aside under `~/.local/share/opencode1-migrations`,
never deleted).

Manual alternative: download `opencode_<ver>_aarch64.deb` (+ `.sha256`) from
[Releases](https://github.com/DARKBOYJYOTI/termux-opencode/releases) (or a
[build workflow artifact](https://github.com/DARKBOYJYOTI/termux-opencode/actions/workflows/build-opencode-native.yml)),
verify the checksum, and `dpkg -i` it.

### Upgrade / downgrade

```bash
dpkg -i opencode_<new-ver>_aarch64.deb   # upgrade
dpkg -i opencode_<old-ver>_aarch64.deb   # downgrade (same command)
```

`opencode upgrade` is wired to this repository: it checks our releases and
installs the matching `.deb` (checksum-verified), exactly like the installer.
`opencode upgrade <version>` pins a version. The upstream upgrade flow is
never reached, so an official build can never overwrite this hardened
runtime.

### Update notifications (this repo's releases)

Releases here are tagged `opencode-<ver>` (e.g. `opencode-1.19.1`). The
launcher checks that feed — at most once a day (cached), only for interactive
terminal sessions, and silently when offline:

```text
Update available: opencode 1.19.2 (installed 1.19.1).
Get it: https://github.com/DARKBOYJYOTI/termux-opencode/releases (dpkg -i opencode_1.19.2_aarch64.deb)
```

Opt out any time: `TERMUX_OPENCODE_UPDATE_CHECK=0`.

### Uninstall

```bash
opencode uninstall              # remove the package, keep all user data
opencode uninstall --dry-run    # show what would be removed, change nothing
opencode uninstall --purge-data # also remove ~/.config/opencode,
                                # ~/.local/share/opencode, ~/.cache/opencode,
                                # ~/.local/state/opencode (asks first, --force skips)
```

Unlike upstream (which deletes data dirs by default), the default here never
touches user data. Running processes are never killed automatically — if any
are still alive you get their PIDs and stop them yourself.

## What's inside the package

| Path | Purpose |
| --- | --- |
| `$PREFIX/bin/opencode` | Launcher: `GH_CONFIG_DIR` passthrough, official update checks off, repo release notice, `upgrade`/`uninstall` routing |
| `$PREFIX/lib/opencode1/runtime/opencode` | Hardened native Bionic runtime (`lib/opencode1` is an internal path kept for loader compatibility) |
| `$PREFIX/lib/opencode/libopencode-crhandler.so` | Self-activating seccomp shim (`close_range` SIGSYS fix) |
| `$PREFIX/lib/opencode1/install.sh` | Shipped installer serving `opencode upgrade` (repo releases only) |
| `$PREFIX/bin/migrate-to-opencode1.sh` | Data layout helper (nested-to-plain move, backups, plugin unpatch) |

Any v1 native package that lacks the `libopencode-crhandler.so` reference is
rejected at packaging time — an unhardened binary cannot start on
seccomp-filtered Android kernels.

## How it works

1. The official `opencode-linux-arm64` release tarball provides the
   JavaScript module graph (byte-identical upstream input).
2. The transplant pipeline grafts it onto the pinned Android Bun base,
   producing a Bionic executable.
3. The vendored, guard-verified Bionic `libopentui.so`
   (`assets/bionic-libopentui-0.4.5.so`, SHA-256 pinned) replaces the
   glibc-linked TUI library, and a zero-displacement patch links the
   self-activating seccomp shim as the first `DT_NEEDED` entry.
4. The result is packaged as `opencode`, with the shim presence asserted —
   the build fails closed instead of shipping a binary that SIGSYS-crashes.

Final runtime acceptance always happens on a real Termux device.

## Build from source

### Option A — GitHub Actions (recommended)

`Actions → Build opencode native Android package → Run workflow`, with input
`version` (e.g. `1.19.1`). The workflow downloads the upstream tarball,
transplants, grafts the Bionic TUI library, hardens, packages **only**
`opencode`, and uploads the `.deb` + SHA-256 + build report.

### Option B — On-device (Termux, AArch64)

```bash
# 1. Transplant the official tarball onto the Android Bun base
npm pack 'opencode-linux-arm64@1.19.1' --pack-destination "$TMPDIR"
python3 tools/transplant/transplant.py all \
  --ver 1.19.1 --tgz "$TMPDIR/opencode-linux-arm64-1.19.1.tgz"

# 2. Graft the vendored Bionic TUI library
python3 tools/transplant/swap_tui.py \
  --binary artifacts/transplant/1.19.1/opencode-native-revived \
  --tui-lib assets/bionic-libopentui-0.4.5.so \
  --out artifacts/transplant/1.19.1/opencode-native-tui

# 3. Harden (needs clang), package, install, verify
clang -shared -fPIC -O2 \
  -o artifacts/transplant/1.19.1/libopencode-crhandler.so tools/shim/sigsys_handler.c
python3 tools/transplant/crhandler_patch.py artifacts/transplant/1.19.1/opencode-native-tui
ARCH_DEB=aarch64 VERSION=1.19.1 \
  TRANSPLANT_ROOT="$PWD/artifacts/transplant" \
  bash ./scripts/package/package_deb_native.sh
dpkg -i packing/dpkg-native/opencode_1.19.1_aarch64.deb
opencode --version
```

## Repository layout

```text
.github/workflows/build-opencode-native.yml   # reproducible v1-only CI build
.github/workflows/tests.yml                   # shell unit tests on push/PR
assets/bionic-libopentui-0.4.5.so              # vendored Bionic TUI lib (SHA-256 pinned)
scripts/opencode-launcher.sh                   # shipped launcher (source of bin/opencode)
scripts/package/package_deb_native.sh          # native .deb packager (shim is mandatory for v1)
scripts/common.sh, fetch-fixtures.sh, ...      # shared helpers
tools/transplant/                              # transplant + revive + harden pipeline
tools/shim/sigsys_handler.c                    # seccomp handler source
tools/build-bionic/                            # Bionic platform patch helpers
patches/opentui/                               # guard patches for the Bionic libopentui build
tests/                                         # shell unit tests + transplant golden regression
```

## Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| `Bad system call`, exit 159 | Missing/blocked `close_range` shim | Reinstall this repo's package; never mix in official binaries |
| `libm.so.6 not found` at TUI start | glibc `libopentui.so` in the bundle | Rebuild via this pipeline (Bionic graft step) |
| `gh` asks to log in under `opencode` | Stale launcher without `GH_CONFIG_DIR` passthrough | Upgrade to the current package |
| TUI stalls waiting for background service | Stale `serve` daemon after upgrade | Kill old `opencode serve` processes, relaunch |
| No update notice despite new release | Cache (< 24 h), non-TTY session, or offline | Wait a day, run in a terminal, check network |

## Contributing

- Single branch: `main`. Keep changes small, additive, and tested.
- Run `./tests/run.sh` before pushing.
- Never commit generated artifacts (`artifacts/`, `*.deb`, `*.tgz`), credentials,
  tokens, or device-specific paths — see [SECURITY.md](./SECURITY.md).
- Packaging scripts fail closed: if a guard trips, fix the pipeline, don't
  weaken the check.

## Security

See [SECURITY.md](./SECURITY.md) for reporting and secret-handling policy.

## Credits

- [anomalyco/opencode](https://github.com/anomalyco/opencode) — the original
  OpenCode this project packages.
- [Hope2333/opencode-termux](https://github.com/Hope2333/opencode-termux) —
  whose transplant and seccomp-hardening research this build pipeline is based on.

## License

MIT — see [LICENSE](./LICENSE).
