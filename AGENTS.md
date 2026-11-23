# AGENTS.md — termux-opencode contributor guide

> Read this file before doing anything in this repository. It is the single
> source of truth for how this project is built, released, and maintained.

## 1. Overview

`termux-opencode` ships native OpenCode **v2** (2.x) as the plain `opencode`
command for **Termux on Android (AArch64)**. Pure Bionic runtime, zero glibc
dependencies, full TUI (libopentui 0.8.4 built in CI). Single branch
(`main`), v2-only, reproducible builds, verified on a real device.

- Upstream input is always byte-identical official release material
  (`@opencode/cli-linux-arm64@<ver>` npm tarball). We never fork upstream code.
- This repository is the **only supported upgrade path**. The official
  installer, official auto-update, and official binaries must never be mixed
  into these packages or recommended to users.

## 2. Repository map

| Path | Role |
| --- | --- |
| `install.sh` | One-line user installer (repo releases only, checksum-verified) |
| `scripts/opencode-launcher.sh` | Shipped launcher — source of `$PREFIX/bin/opencode`; routes `upgrade`/`uninstall`, never re-roots XDG |
| `scripts/package/package_deb_native.sh` | Native `.deb` packager; verifies the stripped update channel |
| `scripts/common.sh` | Shared shell helpers (unit-tested) |
| `tools/transplant/` | Transplant + revive + harden pipeline (stdlib-only Python) |
| `patches/opentui/android-bionic-0.8.4.patch` | 0.8.4 bionic build + FFI guard patches |
| `tools/transplant/build-libopentui-0.8.4.sh` | Reproducible bionic libopentui 0.8.4 build |
| `tests/` | Shell unit tests (bats) |
| `.github/workflows/build-opencode-native.yml` | Manual-dispatch CI build (v2 only) |
| `.github/workflows/tests.yml` | Shell unit tests on push/PR |

## 3. Build pipeline (must run in this order)

1. **Transplant** — graft the official module graph onto the pinned Android
   Bun base:
   `python3 tools/transplant/transplant.py all --ver <V> --tgz <tgz>`
2. **TUI graft** — build the bionic libopentui 0.8.4
   (`tools/transplant/build-libopentui-0.8.4.sh`) and swap the glibc
   libopentui inside the binary for it (slot must fit; swap fails loudly):
   `python3 tools/transplant/swap_tui.py --binary <revived> --tui-lib artifacts/transplant/opentui-0.8.4/libopentui.so --out <tui>`
3. **Strip official update** — same-length edits to the plaintext module graph
   remove the official update channel structurally (anchor set `2.3.2`: the
   autoupdate gate is forced off and the palette `opencode.update` command is
   removed; the CLI `upgrade` subcommand stays, but the launcher serves it
   from this repository). Every anchor must occur exactly once, else fail
   closed:
   `python3 tools/transplant/strip_official_update.py <tui-binary>`
   The packager refuses a runtime that still carries any stripped anchor.
4. **Package** — `ARCH_DEB=aarch64 VERSION=<V> TRANSPLANT_ROOT=<dir>
   bash ./scripts/package/package_deb_native.sh`
   The packager **fails closed**: a runtime with the official update channel
   (anchor set `2.3.2`) is refused. v2 needs no seccomp shim.

CI (`--no-execve`) produces the binary; **final acceptance is always on a
real Termux device**: `opencode --version` prints the version, the TUI starts
and stays up, no `libm.so.6` / SIGSYS errors.

## 4. Release flow

- Release tags: `opencode-<ver>` (e.g. `opencode-2.3.2`). Never reuse an
  upstream-only tag form — the launcher's update check matches `opencode-*`.
- Attach `opencode_<ver>_aarch64.deb` **and** `opencode_<ver>_aarch64.deb.sha256`
  (format: `<hash>  <path>`; the installer compares field 1).
- Publish only after on-device acceptance (section 3). To roll back, keep the
  previous release published and reinstall its `.deb` — user data lives in
  `$HOME` and survives package swaps.
- To re-ship the same version (e.g. fixed packaging, same upstream binary):
  rebuild via CI, verify the new artifact on-device with a before/after data
  tree diff (section 9), then `gh release delete-asset` the old files and
  upload the new ones. Never push a second tag for the same version.
- New upstream minor/patch (same `@opentui/core`): dispatch the workflow with
  the new version. If `@opentui/core` changed, the vendored Bionic lib must
  be rebuilt and re-pinned first — do not ship a version whose TUI asset was
  never smoke-tested.

## 5. Update-channel policy (code-level)

- The official update channel is removed at BUILD time
  (`tools/transplant/strip_official_update.py`, section 3). Six same-length
  edits to the embedded module graph: (1) hardwire the
  `OPENCODE_DISABLE_AUTOUPDATE` flag default true; (2) short-circuit the auto
  detection function; (3) make the TUI `/update` palette entry never register;
  (4) force the `Installation.upgrade` guard true so any in-process official
  install throws before touching the network/filesystem (covers the dialog's
  `apply()`, the server route, and a direct `runtime/opencode upgrade`); (5)
  point the `POST /global/upgrade` route at a non-existent path (404); (6) stop
  the updater wrapper's version fetch. No official check, notice, `/update`
  command, or update dialog can exist even if the environment is bypassed or
  the runtime is invoked directly. The packager fails closed if any anchor is
  still present. Anchors are grouped per known upstream build (minified
  identifiers drift between releases); an unknown layout fails closed, so a
  bump that renames identifiers needs a newly verified anchor set.
- The launcher ALSO exports `OPENCODE_DISABLE_AUTOUPDATE=1` (belt and
  suspenders). The upstream `upgrade` flow (including its "Install anyways?"
  prompt) is never reachable.
- `opencode upgrade [version]` is intercepted by the launcher and served by
  the shipped `$PREFIX/lib/opencode1/install.sh` (packaged from repo root
  `install.sh`): it installs this repo's releases, never upstream's. All
  other subcommands pass through to the runtime untouched. The packager
  fails the build if `install.sh` is missing.
- `opencode uninstall [--purge-data] [--force] [--dry-run]` is intercepted
  the same way (upstream's uninstall deletes data dirs by default — never
  reach it). Default removes only the package (`dpkg -r`) and keeps all user
  data; `--purge-data` removes exactly the four official data roots after
  confirmation. Purge targets are derived from `$HOME` (ambient XDG
  normalized) and each must match `$HOME/*opencode*` or the run aborts.
- Never auto-kill processes on uninstall: the binary-path pattern also
  matches the invoking agent/background sessions, and killing them strands
  the user mid-operation (observed live). Print PIDs and let the operator
  stop them. The postinst kill hook targets only
  `$PREFIX/lib/opencode2/runtime/opencode`.
- Our own notice lives in the launcher (`_termux_opencode_update_notice`):
  queries this repo's `releases/latest`, matches tag `opencode-*`, compares
  with `sort -V` against the installed `dpkg` version. Constraints, in order:
  opt-out via `TERMUX_OPENCODE_UPDATE_CHECK=0`; TTY-only (`[ -t 1 ]`); at most
  once per 24 h (file cache under `$XDG_CACHE_HOME/opencode/`); silent on any
  failure. Never make it blocking, never let it fail the launch (function
  ends `return 0`; the file runs under `set -euo pipefail`).
- `install.sh` never touches shell config, never adds aliases, never contacts
  the official channel. It runs `pkg update`, ensures `curl` +
  `ca-certificates`, verifies SHA-256 (aborts on mismatch), removes legacy
  `opencode1` and the stale `hope2333-bootstrap` apt source, then installs.
- Like upstream `upgrade`, it stops early with "already on … — nothing to
  do" when the requested version is already installed; `--reinstall` forces
  a reinstall. The launcher forwards `opencode upgrade [version]
  [--reinstall]` accordingly (`-h` shows installer usage).

## 6. Naming and layout constraints (do not "clean up")

- User-facing names are `opencode` everywhere (command, package, docs).
- Data layout is the **official plain structure** (`<root>/opencode`), exactly
  like upstream — the launcher sets no XDG re-rooting. Verify with live fds
  (`ls -l /proc/<runtime-pid>/fd`), never declarations.
- `lib/opencode1/` (runtime dir) is an **internal detail kept for loader
  compatibility**: the binary's `DT_RUNPATH` (`$ORIGIN/../lib/opencode`)
  resolves through it. Do not rename it without re-hardening the binary.
- The launcher injects the v1-parity default `Tab` -> `agent.cycle`
  (`OPENCODE_CLI_CONFIG_CONTENT`) only when the user's
  `cli.json`/`cli.jsonc` has no `agent.cycle` binding and they did not set
  that variable themselves. CLI settings merge, so user keybinds survive.
- The launcher computes purge/notice paths from the ambient XDG roots
  verbatim (official plain layout, `<root>/opencode`); packaging never moves
  or deletes user data. v2 reads the same roots the v1 packages used.
- Version inputs accept stable v2 only (`^2\.[0-9]+\.[0-9]+$`); 1.x is
  rejected by the workflow and the installer.

## 7. Conventions

- Shell: `set -euo pipefail`, explicit `command -v` checks, actionable error
  messages on stderr with non-zero exit.
- Pipe-safety: `install.sh` runs as `curl … | bash`, so **every** child
  command that could read stdin (`pkg`, `dpkg`, `curl`, final verification)
  gets `< /dev/null`, plus `DEBIAN_FRONTEND=noninteractive`. A tool that
  eats the script stream makes the install stop halfway and resume cleanly
  on re-run — which hides the bug. Always test the installer in real pipe
  mode (`cat install.sh | bash -s -- -v <ver>`), never only as `bash
  install.sh`.
- Installer UI: `step` / `ok` / `warn` / `die` helpers, banner + success box,
  colors only on a TTY and honoring `NO_COLOR`. No animations, no external
  dependencies, no output that breaks `curl … | bash` piping.
- Guards fail closed: a tripped check must stop the build/package, never be
  downgraded to a warning without a recorded reason.
- Keep the launcher dependency-free beyond Termux base + `curl`
  (`dpkg-query`, `sort`, `date`, `grep`, `sed` are base utilities).
- Docs stay in English. Keep README (user surface) and this file (contributor
  surface) consistent when behavior changes.
- Test discipline: this dev session often carries pre-isolated ambient
  `XDG_*_HOME` vars. ALWAYS run app invocations under a clean environment
  (`env -u XDG_CONFIG_HOME -u XDG_DATA_HOME -u XDG_CACHE_HOME -u
  XDG_STATE_HOME …`) or the runtime writes to nested paths and the next
  `replain` will adopt that junk over live plain data. Verify data paths
  with live fds, and snapshot data trees before/after every install.

## 8. Anti-patterns (do not do these)

- Do not weaken or skip the graft/update-strip assertions to "make the build pass".
- Do not commit generated outputs: `artifacts/`, `*.deb`, `*.tgz`,
  `tests/vendor/`, `__pycache__/` (all ignored).
- Do not commit tokens, keys, `.env` files, `hosts.yml` contents, or
  device-specific absolute paths. CI permissions stay minimal; no scheduled
  triggers that pull or publish without human review.
- Do not install or recommend official binaries/installers over these
  packages. Do not re-enable official update checks by default.
- Do not add new networks calls to the launch path except through the
  cached, TTY-gated, silent-on-failure pattern of section 5.

## 9. Testing

```bash
./tests/run.sh                                   # shell unit tests (must pass)
python3 tools/transplant/strip_official_update.py --selftest
bash -n install.sh scripts/opencode-launcher.sh scripts/package/package_deb_native.sh
cat install.sh | bash -s -- -v <ver>             # real pipe-mode installer test
```

On-device acceptance for every release candidate:

1. `opencode --version` prints the exact version.
2. TUI starts under a pty and stays up with no `libm.so.6`, SIGSYS, or
   `Failed to initialize` errors.
3. With a newer release published, an interactive launch prints the update
   notice; when up to date (or offline), it stays silent.
4. `opencode upgrade` (and `--help`) routes to our installer, never to the
   upstream flow.
5. Same-version upgrades skip without downloading (`--reinstall` forces);
   pinned versions install exactly (up or down). Test all three paths.
6. Reinstalls move zero user data: snapshot the data trees before/after
   (`find <dirs> | sort | diff`) and require an empty diff.
7. `opencode uninstall --dry-run` prints the exact plan (official paths).
   Full purge is tested on a fake `HOME` only (`HOME=/tmp/x opencode
   uninstall --purge-data --force` — `dpkg -r` still runs for real, data
   removal stays fake), then the package is reinstalled and files re-synced.
   A default (keep-data) uninstall is verified live: package gone, data
   byte-identical, reinstall clean.

## 10. Troubleshooting map

| Symptom | Root cause | Fix |
| --- | --- | --- |
| `Bad system call`, exit 159 | Unhardened binary (no shim) | Rebuild via section 3; never ship it |
| `libm.so.6 not found` at TUI start | glibc `libopentui` in bundle (swap skipped) | Re-run the graft step; check slot fit |
| `No command opencode1 found` for users | Stale `alias opencode="opencode1"` in `~/.bashrc` | Remove the alias line (installer adds none) |
| Doubled data dirs (`opencode1/opencode1/...`) | Migration ran with pre-isolated ambient XDG vars | Delete only the doubled trees (live data is at plain paths); normalization (section 6) prevents recurrence |
| Uninstaller kills the agent/user session | Auto-`pkill` on the runtime path matches the invoker too | Never auto-kill: warn with PIDs only (section 5) |
| Reinstall re-nests data to `opencode1/` | Old postinst `isolate` path ran on upgrade | Postinst calls `replain` only; verify with before/after tree diff |
| No update notice though release is newer | Cache < 24 h, non-TTY, offline, or opted out | Wait / use a terminal / check network / `TERMUX_OPENCODE_UPDATE_CHECK` |
| `dpkg --audit` complains | Stale third-party package state | `install.sh` cleans the known one; otherwise inspect before forcing |
| Installer stops after the packages step, resumes fine on re-run | A child tool read stdin and ate the piped script stream | Give every child `< /dev/null` (section 7); re-test in pipe mode |

## 11. Credits and license

- Original: [anomalyco/opencode](https://github.com/anomalyco/opencode).
- Transplant/hardening research lineage:
  [Hope2333/opencode-termux](https://github.com/Hope2333/opencode-termux).
- License: MIT (`LICENSE`).
