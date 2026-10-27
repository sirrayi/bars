---
name: bars
description: "bars read. Provider usage, limits, credits, config health. JSON. No writes."
---

# bars

Read bars. Never mutate config/auth.

## Run

```bash
skill="${CODEX_HOME:-$HOME/.codex}/skills/bars"
"$skill/scripts/bars" doctor
"$skill/scripts/bars" providers
"$skill/scripts/bars" usage
"$skill/scripts/bars" usage --provider codex
"$skill/scripts/bars" usage --all
```

All stdout: JSON. Upstream bars shape kept. Less drift, fewer tokens.

## Rules

- Start `doctor` when install/config unknown.
- `usage` reads enabled providers. Prefer this.
- `usage --provider ID` reads one provider.
- `usage --all` expensive; use only when needed.
- Identities hidden by default. `--include-identities` only when user explicitly needs them.
- Secrets always hidden.
- Helper read-only: fixed allowlist only. No config writes, auth repair, enable/disable, key storage.
- Timeout means upstream stuck. Narrow provider or raise `BARS_TIMEOUT` (default 120 seconds).

## Binary

Auto-find: `BARS_BIN`, PATH, app bundle, Homebrew cask. If missing: open bars, Preferences > Advanced > Install CLI; or set `BARS_BIN`.

Each stdout/stderr stream capped at 1 MiB while fully drained. Timeout kills process group.
