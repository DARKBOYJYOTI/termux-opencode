# termux-opencode wiki

Everything about installing, updating, removing, and building the native
OpenCode v2 (`opencode`, 2.x) packages for Termux on Android (AArch64).

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

`termux-opencode` packages official OpenCode v2 releases as native Bionic
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
| `$PREFIX/lib/opencode2/runtime/opencode` | Native Bionic v2 runtime (`lib/opencode2` is an internal path) |
| `$PREFIX/lib/opencode2/install.sh` | Installer serving `opencode upgrade` |

`Tab` cycles the agent (plan/build). The launcher injects this default through
`OPENCODE_CLI_CONFIG_CONTENT` unless `cli.json` already configures
`keybinds.agent.cycle` (or you set that variable yourself); CLI settings merge,
so other keybindings are untouched.

Any package whose runtime still carries the official update channel is refused
at packaging time.

## How it works

1. The official `opencode-linux-arm64` release tarball provides the
   JavaScript module graph (byte-identical upstream input).
2. The transplant pipeline grafts it onto the pinned Android Bun base.
3. The guard-verified Bionic `libopentui.so`
   (built by `tools/transplant/build-libopentui-0.8.4.sh`) replaces the
   glibc-linked TUI library.
4. The official update channel is stripped structurally and the result is
   packaged as `opencode`; packaging fails closed on an unstripped runtime.

Final runtime acceptance always happens on a real Termux device.

## Build from source

Via CI (recommended): `Actions → Build opencode native Android package →
Run workflow` with input `version`. It downloads the upstream tarball,
transplants, grafts, strips the update channel, packages **only**
`opencode`, and uploads the `.deb` + SHA-256 + build report.

On-device (Termux, AArch64), with `<ver>` being the target version:

```bash
npm pack "@opencode/cli-linux-arm64@<ver>" --pack-destination "$TMPDIR"
python3 tools/transplant/transplant.py all --ver <ver> --tgz "$TMPDIR/opencode-cli-linux-arm64-<ver>.tgz"
python3 tools/transplant/swap_tui.py \
  --binary artifacts/transplant/<ver>/opencode-native-revived \
  --tui-lib artifacts/transplant/opentui-0.8.4/libopentui.so \
  --out artifacts/transplant/<ver>/opencode-native-tui
python3 tools/transplant/strip_official_update.py artifacts/transplant/<ver>/opencode-native-tui
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
