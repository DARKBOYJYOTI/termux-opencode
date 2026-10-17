# termux-opencode

[![opencode native build](https://github.com/DARKBOYJYOTI/termux-opencode/actions/workflows/build-opencode-native.yml/badge.svg?branch=main)](https://github.com/DARKBOYJYOTI/termux-opencode/actions/workflows/build-opencode-native.yml)
[![Unit Tests](https://github.com/DARKBOYJYOTI/termux-opencode/actions/workflows/tests.yml/badge.svg?branch=main)](https://github.com/DARKBOYJYOTI/termux-opencode/actions/workflows/tests.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-3fb950?style=flat-square)](./LICENSE)
[![Termux: AArch64](https://img.shields.io/badge/Termux-AArch64-1f6feb?style=flat-square)](https://termux.dev)

Native [OpenCode](https://opencode.ai) v1 (`opencode`) for **Termux on
Android (AArch64)** — installed, updated, and uninstalled the way `opencode`
users expect, served entirely from this repository. Pure Bionic runtime,
full TUI, verified on real devices.

> This repository is the only supported upgrade path. The official update
> channel is removed from the runtime at build time — no update checks, no
> `/update` command, no notices, no update dialog. Releases, notices, and
> upgrades all come from here. Details: [wiki.md](./wiki.md).

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/DARKBOYJYOTI/termux-opencode/main/install.sh | bash
```

Then `opencode --version` and `opencode` to start. Details and options
(pinned versions, manual `.deb` install): [wiki.md](./wiki.md#install).

## Upgrade

```bash
opencode upgrade            # latest release (skips if already there)
opencode upgrade <version>  # pinned version, up or down
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

Android 9+, AArch64, Termux, ~1 GB free. Data lives in the official plain
layout — plugins and scripts work unpatched. Full guide: [wiki.md](./wiki.md).

## Contributing

Single branch `main`; run `./tests/run.sh` before pushing; never commit
build outputs, credentials, or device paths — see [SECURITY.md](./SECURITY.md).

## Credits

- [anomalyco/opencode](https://github.com/anomalyco/opencode) — the original OpenCode.
- [Hope2333/opencode-termux](https://github.com/Hope2333/opencode-termux) — transplant/hardening research this builds on.

## License

MIT — see [LICENSE](./LICENSE).
