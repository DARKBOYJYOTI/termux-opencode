# OpenCode for Termux (Android AArch64) — native .deb, full TUI

[![opencode native build](https://github.com/DARKBOYJYOTI/termux-opencode/actions/workflows/build-opencode-native.yml/badge.svg?branch=main)](https://github.com/DARKBOYJYOTI/termux-opencode/actions/workflows/build-opencode-native.yml)
[![Unit Tests](https://github.com/DARKBOYJYOTI/termux-opencode/actions/workflows/tests.yml/badge.svg?branch=main)](https://github.com/DARKBOYJYOTI/termux-opencode/actions/workflows/tests.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-3fb950?style=flat-square)](./LICENSE)
[![Termux: AArch64](https://img.shields.io/badge/Termux-AArch64-1f6feb?style=flat-square)](https://termux.dev)
[![Latest release](https://img.shields.io/github/v/release/DARKBOYJYOTI/termux-opencode?label=release&style=flat-square)](https://github.com/DARKBOYJYOTI/termux-opencode/releases/latest)

Install **OpenCode** on **Termux/Android** (arm64 / AArch64) with one command.
This is a native [OpenCode](https://opencode.ai) v2 build for Bionic, packaged as
a Debian `.deb`, with the full TUI. It needs **no root**, **no proot**, and no
glibc workarounds.

Current release: **opencode 2.4.1** — see
[releases](https://github.com/DARKBOYJYOTI/termux-opencode/releases/latest).
Tested on Android 12 and Android 16 (Termux, AArch64).

## Install OpenCode on Termux

```bash
curl -fsSL https://raw.githubusercontent.com/DARKBOYJYOTI/termux-opencode/main/install.sh | bash
```

Then `opencode --version` and `opencode` to start. Details and options
(pinned versions, manual `.deb` install): [wiki.md](./wiki.md#install).

## Why this build instead of the official binary

- **Bionic runtime** — links `/system/bin/linker64` and `libc.so`, the same
  libc Android itself uses. No proot, no glibc container, no PATH hacks.
- **Full TUI** — `libopentui.so` **0.9.4** is rebuilt for `aarch64-linux-android`
  in CI (zig 0.17.1) and grafted into the payload, instead of the glibc library
  the upstream standalone bundles.
- **Android-safe pointers** — heap tagging is disabled at startup so the TUI's
  FFI layer can pass pointers as JS numbers on Android 11+.
- **Self-hosted update channel** — the launcher disables the official
  background check and serves `upgrade`/`uninstall` from this repository. This
  repository is the only supported upgrade path; official binaries are never
  downloaded.
- **Standard data layout** — `~/.config/opencode` and `~/.local/share/opencode`
  stay in the official plain layout, so plugins, agents, and scripts work
  unmodified.
- `Tab` cycles the agent (plan/build), matching the v1 keybinding; set
  `keybinds.agent.cycle` in `cli.json` to override.

## Upgrade

```bash
opencode upgrade             # latest release (skips if already there)
opencode upgrade <version>   # pinned version, up or down
opencode upgrade --reinstall # force reinstall
```

A once-daily notice tells you when a release is newer
(`TERMUX_OPENCODE_UPDATE_CHECK=0` opts out). Details:
[wiki.md](./wiki.md#upgrade).

## Uninstall

```bash
opencode uninstall              # remove package, keep data
opencode uninstall --purge-data # also remove app data (asks first)
```

Details: [wiki.md](./wiki.md#uninstall).

## Requirements

- Termux on Android 9+ (arm64 / AArch64 device)
- ~1 GB free space
- No root and no proot required

## FAQ

**Does OpenCode work on Android?**
Yes. This repository ships a native Termux package for OpenCode v2, including
the full terminal UI.

**Do I need proot or proot-distro to run OpenCode in Termux?**
No. The runtime is built against Android's Bionic libc and runs directly in
Termux.

**Which CPU architectures are supported?**
AArch64 (arm64) only. x86_64 Android and 32-bit arm are not supported.

**How do I update OpenCode on Termux?**
Run `opencode upgrade`. It checks this repository's latest release, verifies
the `.deb` checksum, and installs it with `dpkg`.

**Will I lose my sessions, config, or plugins when I upgrade?**
No. Upgrades replace the package only. Data under `~/.config/opencode` and
`~/.local/share/opencode` is untouched; `opencode uninstall` keeps it too
unless you pass `--purge-data`.

**Can I install the official OpenCode binary instead?**
The official Linux build is linked against glibc and does not start in Termux.
Use the `.deb` from this repository.

## Documentation

- [wiki.md](./wiki.md) — install, upgrade, uninstall, troubleshooting, build internals.
- [AGENTS.md](./AGENTS.md) — repository map and release flow.
- [SECURITY.md](./SECURITY.md) — trust model and what the installer touches.

## Contributing

Single branch `main`; run `./tests/run.sh` before pushing; never commit
build outputs, credentials, or device paths — see [SECURITY.md](./SECURITY.md).

## Credits

- [anomalyco/opencode](https://github.com/anomalyco/opencode) — the original OpenCode.
- [Hope2333/opencode-termux](https://github.com/Hope2333/opencode-termux) — transplant/hardening research this builds on.

## License

MIT — see [LICENSE](./LICENSE).
