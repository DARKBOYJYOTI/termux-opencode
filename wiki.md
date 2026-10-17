# termux-opencode wiki

Everything about installing, updating, removing, and building the native
OpenCode v1 (`opencode`) packages for Termux on Android (AArch64).

- [About](#about)
- [Install](#install)
- [Upgrade](#upgrade)
- [Uninstall](#uninstall)
- [Update notices](#update-notices)
- [Data layout](#data-layout)
- [Package contents](#package-contents)
- [How it works](#how-it-works)
- [Build from source](#build-from-source)
- [Releases](#releases)
- [Troubleshooting](#troubleshooting)
- [Development](#development)

## About

`termux-opencode` packages official OpenCode v1 releases as native Bionic
binaries for Termux. The command is the plain `opencode` name and the data
layout is the official plain structure, so plugins, MCP setups, and scripts
work without patching.

This repository — its releases, installer, and in-app notices — is the only
supported upgrade path. The official installer, official auto-update, and
official binaries must never be mixed into these packages.

## Install

One line — updates Termux lists, ensures `curl` + `ca-certificates`,
downloads the latest release, verifies its SHA-256 checksum, replaces any
legacy `opencode1` package (data preserved), and verifies the install:

```bash
curl -fsSL https://raw.githubusercontent.com/DARKBOYJYOTI/termux-opencode/main/install.sh | bash
```

Pin a version:

```bash
curl -fsSL https://raw.githubusercontent.com/DARKBOYJYOTI/termux-opencode/main/install.sh | bash -s -- -v <ver>
```

The installer never touches shell config, never adds aliases, and never
contacts the official OpenCode channel.

Manual alternative: download `opencode_<ver>_aarch64.deb` (+ `.sha256`)
from [Releases](https://github.com/DARKBOYJYOTI/termux-opencode/releases),
verify the checksum yourself, and `dpkg -i` it.

## Upgrade

```bash
opencode upgrade            # latest release (skips when already there)
opencode upgrade <version>  # pinned version — upgrades and downgrades alike
opencode upgrade --reinstall # force a reinstall of the same version
```

Behavior: resolves the target (explicit version, else our latest release),
compares it with the installed version, and stops with "already on … —
nothing to do" unless there is something newer (or `--reinstall` is given).
Downloads are checksum-verified. The runtime's own update channel is removed
at build time (no `/update` command, no official check, and every in-process
official install path is disabled), so an official build can never overwrite
this hardened runtime. `dpkg -i` with a `.deb` works too.

## Uninstall

```bash
opencode uninstall              # remove the package, keep all user data
opencode uninstall --dry-run    # show what would be removed, change nothing
opencode uninstall --purge-data # also remove the four data dirs below (asks first)
opencode uninstall --purge-data --force  # skip the confirmation (scripts)
```

Unlike upstream (which deletes data dirs by default), the default here never
touches user data. Running processes are never killed automatically — if any
are still alive you get their PIDs and stop them yourself.

After uninstalling, your current shell may still remember the old command
path — open a new terminal or run `hash -r`. Verify with
`dpkg-query -W opencode` (expect "package 'opencode' is not installed").

## Update notices

Releases here are tagged `opencode-<ver>`. The launcher checks that feed —
at most once a day (cached), only for interactive terminal sessions, and
silently when offline:

```text
Update available: opencode <new> (installed <old>).
Run: opencode upgrade  (or: https://github.com/DARKBOYJYOTI/termux-opencode/releases)
```

Opt out any time: `TERMUX_OPENCODE_UPDATE_CHECK=0`.

## Data layout

Official plain structure, exactly like upstream:

- `~/.config/opencode` — config, plugins
- `~/.local/share/opencode` — sessions database, auth, repos
- `~/.cache/opencode` — models, temporary files
- `~/.local/state/opencode` — locks, history

If legacy nested `opencode1/` data from older builds exists, it is moved
back once, non-destructively (conflicting plain dirs are backed aside under
`~/.local/share/opencode1-migrations`, never deleted).

## Package contents

| Path | Purpose |
| --- | --- |
| `$PREFIX/bin/opencode` | Launcher (update checks off, repo notice, `upgrade`/`uninstall` routing) |
| `$PREFIX/lib/opencode1/runtime/opencode` | Hardened native Bionic runtime (`lib/opencode1` is an internal loader path) |
| `$PREFIX/lib/opencode/libopencode-crhandler.so` | Self-activating seccomp shim (`close_range` fix) |
| `$PREFIX/lib/opencode1/install.sh` | Installer serving `opencode upgrade` |
| `$PREFIX/bin/migrate-to-opencode1.sh` | Data layout helper |

Any v1 package lacking the `libopencode-crhandler.so` reference is refused
at packaging time — an unhardened binary cannot start on seccomp-filtered
Android kernels.

## How it works

1. The official `opencode-linux-arm64` release tarball provides the
   JavaScript module graph (byte-identical upstream input).
2. The transplant pipeline grafts it onto the pinned Android Bun base.
3. The vendored, guard-verified Bionic `libopentui.so`
   (`assets/bionic-libopentui-0.4.5.so`, SHA-256 pinned) replaces the
   glibc-linked TUI library, and a zero-displacement patch links the
   self-activating seccomp shim as the first `DT_NEEDED` entry.
4. The result is packaged as `opencode`, with the shim asserted — the build
   fails closed instead of shipping a binary that crashes.

Final runtime acceptance always happens on a real Termux device.

## Build from source

Via CI (recommended): `Actions → Build opencode native Android package →
Run workflow` with input `version`. It downloads the upstream tarball,
transplants, grafts, hardens, packages **only** `opencode`, runs the golden
regression, and uploads the `.deb` + SHA-256 + build report.

On-device (Termux, AArch64), with `<ver>` being the target version:

```bash
npm pack 'opencode-linux-arm64@<ver>' --pack-destination "$TMPDIR"
python3 tools/transplant/transplant.py all --ver <ver> --tgz "$TMPDIR/opencode-linux-arm64-<ver>.tgz"
python3 tools/transplant/swap_tui.py \
  --binary artifacts/transplant/<ver>/opencode-native-revived \
  --tui-lib assets/bionic-libopentui-0.4.5.so \
  --out artifacts/transplant/<ver>/opencode-native-tui
clang -shared -fPIC -O2 \
  -o artifacts/transplant/<ver>/libopencode-crhandler.so tools/shim/sigsys_handler.c
python3 tools/transplant/crhandler_patch.py artifacts/transplant/<ver>/opencode-native-tui
ARCH_DEB=aarch64 VERSION=<ver> TRANSPLANT_ROOT="$PWD/artifacts/transplant" \
  bash ./scripts/package/package_deb_native.sh
dpkg -i packing/dpkg-native/opencode_<ver>_aarch64.deb
opencode --version
```

## Releases

- Tags look like `opencode-<ver>` and carry `opencode_<ver>_aarch64.deb` +
  `.sha256`. Publish only after on-device acceptance (version, TUI startup,
  upgrade, uninstall).
- To re-ship a version (same upstream, new packaging): rebuild, verify on
  device with a before/after data-tree diff, then replace the release assets.
  Never push a second tag for one version.

## Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| `Bad system call`, exit 159 | Unhardened binary (no shim) | Reinstall this repo's package; never mix official binaries |
| `libm.so.6 not found` at TUI start | glibc `libopentui.so` in the bundle | Rebuild with the Bionic graft step |
| Installer stops after the packages step | A tool read the piped script stream | Fixed: every child gets stdin from `/dev/null`; re-run |
| `No command opencode1 found` | Stale `alias opencode="opencode1"` in `~/.bashrc` | Remove the alias line |
| No update notice though newer exists | Cache (< 24 h), non-TTY, or offline | Wait a day / use a terminal / check network |
| `gh` asks to log in under `opencode` | Stale launcher | Upgrade to the current package |

## Development

- Single branch `main`; small additive changes; `./tests/run.sh` green before
  pushing. Full contributor rules: [AGENTS.md](./AGENTS.md).
- Never commit build outputs (`artifacts/`, `*.deb`, `*.tgz`), credentials,
  tokens, or device paths — see [SECURITY.md](./SECURITY.md).
- New upstream version? Check its `@opentui/core` first: same as vendored,
  dispatch the workflow; changed, rebuild and re-pin the Bionic lib first.
