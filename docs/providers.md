---
summary: "Provider data sources and parsing overview for every registered CodexBar provider."
read_when:
  - Adding or modifying provider fetch/parsing
  - Adjusting provider labels, toggles, or metadata
  - Reviewing data sources for providers
---

# Providers

CodexBar currently registers 7 provider IDs. Some companies expose multiple surfaces, such as Codex vs OpenAI API or
OpenCode vs OpenCode Go, because the auth source and quota shape differ.


## Fetch strategies (current)
Legend: web (browser cookies/WebView), cli (RPC/PTy or provider CLI), oauth (provider OAuth), api token, local probe, web dashboard.
Source labels (CLI/header): `openai-web`, `web`, `oauth`, `api`, `local`, `cli`, plus provider-specific CLI labels (e.g. `codex-cli`, `claude`).

Cookie-based providers expose a Cookie source picker (Automatic or Manual) in Settings → Providers.
Some browser cookie imports are cached in Keychain and reused until the session is invalid. API keys, manual cookie
headers, source selection, provider ordering, and token accounts are stored in the resolved config file.
New installs use `~/.config/codexbar/config.json`; existing `~/.codexbar/config.json` installs retain that legacy path.
See [CLI configuration](cli-configuration.md) for `XDG_CONFIG_HOME` and `CODEXBAR_CONFIG` overrides.

## Usage & Spend settings

The Statistics time zone picker changes the saved reporting zone. Use Mac's current time zone pins the Mac's
current zone once; later system timezone changes do not override the saved selection.

Settings → Usage & Spend is a local estimated-cost history page, not a billing receipt and not the menu-bar quota
card. Range choices are 7 / 30 / 90 days and All (the scan window is 365 days). Amounts are list-price equivalents
unless a source also reports plan-metered spend, in which case both columns appear. Day buckets use a pinned IANA
timezone stored when cost tracking is first enabled. Heatmap and ledger dates remain aligned to local calendar
days across daylight-saving transitions, including zones where midnight is skipped. Coverage counts civil days,
and daily/hourly chart labels use the bucket time zone. Their ranges end at the next local day boundary rather than a fixed 24 hours.

Regular token-history publications also refresh outdated independent Usage & Spend sources, including Claude,
through their own 365-day scan. The dashboard never substitutes the shorter menu history for that scan. Updates
arriving during a scan coalesce into a follow-up; a failed attempt waits for a new token publication or manual
dashboard refresh before retrying. Codex account-cache ownership and provider-derived spend sources are unchanged.

Native cost-history sources are the descriptors that advertise token-cost support: Codex, Claude,
OpenCode Go, and Devin (local CLI sessions). Providers without that contract are omitted instead of
appearing as empty subscriptions. Each native currency has its own total, ranking, and daily chart; CodexBar never
adds or ranks amounts across currencies.

The page also shows token mix (input / output / cache / reasoning), priced/unpriced/unmetered/estimated coverage,
sessions, Codex projects, and a 365-day token heatmap. A heatmap day with no coverage is a gap, not zero activity,
and is not clickable. Custom list-price overlays are documented in `docs/model-pricing.md`.
Cached and combined reports retain token-class details and known request counts. Coverage is combined from each
source's existing classification, so a priced source cannot hide another source's unpriced or unmetered rows.
The daily ledger retains known request counts when another source cannot count requests and marks that subtotal
with `≥`. If every source omits its request count, the ledger shows a dash. Request-count gaps do not make known
token or cost totals partial, and partial cost estimates do not erase known request counts.
If coverage totals cannot fit, aggregation falls back to existing request or daily-row inference without changing costs or stored data.
Token sums that exceed the supported integer range remain unavailable for that aggregation pass; later rows do not
restore a partial count. Other token classes, pricing, and explicit totals retain their existing meaning. Materialized
missing values continue to follow the existing partial-data rules; no overflow metadata is added to stored reports.

OpenCodex `~/.opencodex/usage.jsonl` is an opt-in, read-only spend source (off by default). It is not a quota
Provider. When both OpenCodex logs and native Codex sessions are present they stay on separate rows; merging would
double-count the same traffic. An optional toggle can hide native Codex while OpenCodex data is present. Export JSON
emits the currently aggregated model (provenance, mix, coverage). Invalid numeric fields are omitted while valid
neighboring fields remain available. Existing cached rows are reparsed once after the numeric parser update;
subsequent unchanged reads continue to reuse the corrected cache.

The view stays local and does not upload usage history. Refreshes retain the last successful model if a replacement
scan fails, while provider/account configuration changes replace obsolete results. Coverage text reports how many
days of the selected local calendar window are covered by the scan window; a 30-day selection is not labeled as
complete when the available scan window covers fewer days.

| Provider | Strategies (ordered for auto) |
| --- | --- |
| Codex | App Auto: OAuth API (`oauth`) → CLI RPC/PTy (`codex-cli`). CLI Auto: Web dashboard (`openai-web`) → CLI RPC/PTy (`codex-cli`). |
| Claude | Admin API key (`api`) when configured; otherwise App Auto: OAuth API (`oauth`) → CLI PTY (`claude`) → Web API (`web`). CLI Auto: Web API (`web`) → CLI PTY (`claude`); on Linux, Web API (`web`) → OAuth API (`oauth`) → CLI PTY (`claude`). |
| OpenCode | Web dashboard via cookies (`web`). |
| OpenCode Go | Unscoped Auto: local SQLite cost history with API overlay (`local+api`) → usage API (`api`) → web dashboard (`web`). Scoped Auto (selected account/manual cookie/workspace): web → local → API. Explicit API/Web: selected source only. |
| Devin | Chromium localStorage session or manual Bearer token → daily and weekly quota API (`web`). |
| DeepSeek | API key from env or token accounts → balance endpoint (`api`). |
| [Pi](pi.md) | Local Pi/OMP assistant transcripts → token history and API-rate cost estimates (`local`); no subscription quota. |

<!-- Generated provider additions: Scripts/regenerate-provider-docs.mjs -->

| Provider | Source |
|---|---|

<!-- End generated provider additions -->

## Codex
- App Auto: OAuth API first; falls back to CLI only when OAuth credentials are missing or auth/refresh is invalid.
- Web dashboard (optional, off by default): `https://chatgpt.com/codex/cloud/settings/analytics#usage` via WebView + browser cookies.
- Battery saver toggle (currently off by default): reduces routine OpenAI web refreshes but still allows explicit manual refreshes.
- CLI RPC default: `codex ... app-server` JSON-RPC (`account/read`, `account/rateLimits/read`).
- CLI PTY: manual diagnostics/parser coverage only; automatic refresh does not launch bare Codex TUI.
- Local cost usage: scans `CODEX_HOME` (or `~/.codex`) `sessions` and sibling `archived_sessions` JSONL files for the configured history window.
- Completed cost catch-up publishes validated cached history without starting another scan. Native and included Pi/OMP caches must cover the requested window; unavailable or incompatible history preserves existing totals until a later refresh. Token timestamps retain the actual cache scan time. This does not resolve catch-up that remains pending while an active log continuously grows.
- Status: Statuspage.io (OpenAI).
- Details: `docs/codex.md`.


## Claude
- Admin API: `sk-ant-admin...` key in Settings/config, token accounts, or `ANTHROPIC_ADMIN_KEY`.
- Admin API shows organization spend/messages summaries with the same inline dashboard pattern as OpenAI API.
- App Auto: OAuth API (`oauth`) → CLI PTY (`claude`) → Web API (`web`).
- CLI Auto: Web API (`web`) → CLI PTY (`claude`).
- Linux CLI Auto: Web API (`web`) → OAuth API (`oauth`) → CLI PTY (`claude`). The OAuth step is skipped without
  usable noninteractive credentials; OAuth request failures fall back to the CLI.
- Local cost usage: scans `CLAUDE_CONFIG_DIR` when set, otherwise `~/.config/claude/projects`,
  `~/.claude/projects` (including current Claude Desktop Code/Cowork CLI sessions), and nested Claude Desktop
  local-agent JSONL files for the configured history window.
- Status: Statuspage.io (Anthropic).
- Details: `docs/claude.md`.


## Devin
- Automatic auth reads the current `auth1_session` token and organization metadata from supported Chromium browsers' localStorage.
- Manual auth accepts the `Authorization: Bearer ...` value from an app.devin.ai request.
- Usage endpoint: `GET /api/<internal-org-id>/billing/quota/usage`.
- Shows daily and weekly quota percentages with their reset timestamps.
- Details: `docs/devin.md`.


## OpenCode
- Web dashboard via browser cookies (`opencode.ai`).
- Status: none yet.
- Details: `docs/opencode.md`.


## OpenCode Go
- Preferred usage source: `GET https://opencode.ai/zen/go/v1/usage` with an API key from Settings,
  `providers[].apiKey`, or `OPENCODE_API_KEY`.
- Web dashboard via browser or manual cookies (`opencode.ai`).
- Unscoped Auto mode prefers local cost history from `~/.local/share/opencode/opencode.db` on macOS and Linux,
  enriches it with API quota windows when configured, then falls back to standalone API and legacy web sources.
- Auto mode stays web-first for selected token accounts, manual cookies, and workspace overrides; explicit Web mode does
  not include local fallback.
- Uses the public usage API for rolling 5-hour, weekly, and monthly usage windows, with the workspace Go page/server
  data retained as a compatibility fallback.
- Optional workspace ID comes from `~/.codexbar/config.json` (`providers[].workspaceID`) or `CODEXBAR_OPENCODEGO_WORKSPACE_ID`.
- Status: none yet.
- Details: `docs/opencodego.md`.


## DeepSeek
- API key via `DEEPSEEK_API_KEY` / `DEEPSEEK_KEY` env var or DeepSeek token accounts.
- Shows total balance with paid vs. granted breakdown; USD preferred when multiple currencies present.
- Optional Platform-session usage includes reported spend per model in its original billing currency and period.
- Status: `https://status.deepseek.com` (link only, no auto-polling).
- Details: `docs/deepseek.md`.


## Cached usage during account refresh

Transient network failures keep the last successful usage for the same account and credential/configuration scope,
including multi-account menus and their widget data. The cached measurement time and source remain unchanged;
failed refreshes do not add fresh utilization-history samples. Normal error reporting still applies after repeated
failures. Authentication failures and invalidated account scopes do not restore cached usage from another scope.

