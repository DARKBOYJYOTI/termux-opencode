# termux-opencode

[![opencode1 native build](https://github.com/DARKBOYJYOTI/termux-opencode/actions/workflows/build-opencode1-native.yml/badge.svg?branch=main)](https://github.com/DARKBOYJYOTI/termux-opencode/actions/workflows/build-opencode1-native.yml)
[![Unit Tests](https://github.com/DARKBOYJYOTI/termux-opencode/actions/workflows/tests.yml/badge.svg?branch=main)](https://github.com/DARKBOYJYOTI/termux-opencode/actions/workflows/tests.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-3fb950?style=flat-square)](./LICENSE)
[![Termux: AArch64](https://img.shields.io/badge/Termux-AArch64-1f6feb?style=flat-square)](https://termux.dev)
[![Runtime: Bionic](https://img.shields.io/badge/Runtime-Bionic-9e6a03?style=flat-square)](#how-it-works)

Native [OpenCode](https://opencode.ai) v1 (`opencode1`) packages for **Termux on
Android (AArch64)**. Pure Bionic runtime, zero glibc dependencies, full TUI —
built reproducibly and verified on a real device.

> **Update-channel policy:** this repository is the only supported upgrade
> path. Official-channel update checks and notices are disabled in the shipped
> launcher (`OPENCODE_DISABLE_AUTOUPDATE=1`). Never run the official installer
> over these packages — install the next release from here instead.

## Status

| Item | State |
| --- | --- |
| Current package | `opencode1` **1.19.1** (`aarch64` `.deb`) |
| Runtime | Transplanted native Bionic ELF + `libopencode-crhandler.so` seccomp shim + Bionic `libopentui.so` |
| Verified on | Termux on Android 12 (API 31), kernel 4.14 — `--version`, TUI startup |
| CI | Manual-dispatch workflow builds, hardens, packages, and regression-tests every release |

## Requirements

- Android API level 28+ (Android 9.0+), AArch64 device
- [Termux](https://termux.dev) (F-Droid or GitHub release)
- ~1 GB free storage for the install (~200 MB runtime + data)
- For local builds: `make`, `python3`, `clang`, `git`, network access to npm and GitHub

## Install

1. Download the `opencode1_<ver>_aarch64.deb` from the
   [build workflow artifacts](https://github.com/DARKBOYJYOTI/termux-opencode/actions/workflows/build-opencode1-native.yml)
   of a successful run (or a GitHub Release, when published).
2. Install and verify:

```bash
dpkg -i opencode1_1.19.1_aarch64.deb
opencode1 --version   # must print 1.19.1
```

3. Launch the TUI with `opencode1`. Existing v1 data is migrated once,
   non-destructively, into isolated `opencode1/` directories — the plain
   `opencode/` paths are left untouched for v2.

### Upgrade / downgrade

```bash
dpkg -i opencode1_<new-ver>_aarch64.deb   # upgrade
dpkg -i opencode1_<old-ver>_aarch64.deb   # downgrade (same command)
```

Explicit `opencode1 upgrade` still works, but it pulls from the official
channel and is **not supported** here — it can replace this hardened runtime
with an unpatched binary that crashes on older Android kernels.

## What's inside the package

| Path | Purpose |
| --- | --- |
| `$PREFIX/bin/opencode1` | Launcher: XDG isolation, service-port split, `GH_CONFIG_DIR` passthrough, update checks off |
| `$PREFIX/lib/opencode1/runtime/opencode` | Hardened native Bionic runtime |
| `$PREFIX/lib/opencode/libopencode-crhandler.so` | Self-activating seccomp shim (`close_range` SIGSYS fix) |
| `$PREFIX/bin/migrate-to-opencode1.sh` | One-time, idempotent v1 data migration helper |

Any v1 native package that lacks the `libopencode-crhandler.so` reference is
rejected at packaging time — an unhardened binary cannot start on
seccomp-filtered Android kernels.

## How it works

1. The official `opencode-linux-arm64` release tarball provides the
   JavaScript module graph (byte-identical upstream input).
2. The transplant pipeline grafts it onto the pinned Android Bun base,
   producing a Bionic executable.
3. A guard-verified Bionic `libopentui.so` replaces the glibc-linked TUI
   library, and a zero-displacement patch links the self-activating seccomp
   shim as the first `DT_NEEDED` entry.
4. The result is packaged as `opencode1`, with the shim presence asserted —
   the build fails closed instead of shipping a binary that SIGSYS-crashes.

Final runtime acceptance always happens on a real Termux device.

## Build from source

### Option A — GitHub Actions (recommended)

`Actions → Build opencode1 native Android package → Run workflow`, with input
`version` (e.g. `1.19.1`). The workflow downloads the upstream tarball,
transplants, hardens, packages **only** `opencode1`, and uploads the `.deb` +
SHA-256 + build report.

### Option B — On-device (Termux, AArch64)

```bash
# 1. Transplant the official tarball onto the Android Bun base
npm pack 'opencode-linux-arm64@1.19.1' --pack-destination "$TMPDIR"
python3 tools/transplant/transplant.py all \
  --ver 1.19.1 --tgz "$TMPDIR/opencode-linux-arm64-1.19.1.tgz"

# 2. Graft the Bionic TUI library
python3 tools/transplant/swap_tui.py \
  --binary artifacts/transplant/1.19.1/opencode-native-revived \
  --tui-lib artifacts/transplant/opentui-bionic/libopentui.so \
  --out artifacts/transplant/1.19.1/opencode-native-tui

# 3. Harden (needs clang), package, install, verify
clang -shared -fPIC -O2 \
  -o artifacts/transplant/1.19.1/libopencode-crhandler.so tools/shim/sigsys_handler.c
python3 tools/transplant/crhandler_patch.py artifacts/transplant/1.19.1/opencode-native-tui
ARCH_DEB=aarch64 VERSION=1.19.1 \
  TRANSPLANT_ROOT="$PWD/artifacts/transplant" \
  bash ./scripts/package/package_deb_native.sh
dpkg -i packing/dpkg-native/opencode1_1.19.1_aarch64.deb
opencode1 --version
```

## Repository layout

```text
.github/workflows/build-opencode1-native.yml  # reproducible v1-only CI build
.github/workflows/tests.yml                   # shell unit tests on push/PR
scripts/opencode1-launcher.sh                  # shipped launcher (source of bin/opencode1)
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
| `gh` asks to log in under `opencode1` | Stale launcher without `GH_CONFIG_DIR` passthrough | Upgrade to the current package |
| TUI stalls waiting for background service | Stale `serve` daemon after upgrade | Kill old `opencode1 serve` processes, relaunch |

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
