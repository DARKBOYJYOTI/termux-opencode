# Security policy

## Reporting a vulnerability

- **Do not open a public issue** for anything that could be a live
  vulnerability (remote code execution, credential leaks, supply-chain
  tampering, malicious release artifacts).
- Use GitHub's **private vulnerability reporting**
  (`Security → Report a vulnerability`) on this repository so the report
  stays confidential until a fix is released.
- Include: affected version/package, device and Android details, exact
  reproduction steps, and the full error output. Traces that contain tokens
  or personal paths must be redacted before sending.

## What counts as a security issue here

- A release artifact that does not match its published SHA-256.
- A binary or script in this repo that exfiltrates data or executes
  unsigned remote code at install/run time.
- A packaging step that silently drops a hardening guard (seccomp shim,
  Bionic TUI graft) instead of failing closed.

## Secret-handling rules for contributors

1. **Never commit** tokens (`gho_*`, `ghp_*`, `github_pat_*`), API keys,
   private keys, `~/.config/gh/hosts.yml` contents, or `.env` files.
2. Generated and device-local files are git-ignored and must stay that way:
   `artifacts/`, `*.deb`, `*.tgz`, `tests/vendor/`. If you add a new
   generated path, add it to `.gitignore` in the same change.
3. Authenticate Git operations with a local credential helper or
   `GH_CONFIG_DIR`-scoped `gh` config — never paste tokens into commands,
   scripts, logs, or issues.
4. CI workflows run with minimal `permissions` and manual dispatch for
   builds; do not add scheduled triggers that pull or publish without
   human review.

## Supported versions

Only the latest `opencode` release published by this repository receives
security fixes. Older upstream versions are rebuilt on request but not
patched independently — upgrade to the current package.
