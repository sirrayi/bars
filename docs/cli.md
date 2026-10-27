---
summary: "bars CLI for fetching usage from the command line."
read_when:
  - "You want to call bars data from scripts or a terminal."
  - "Adding or modifying Commander-based CLI commands."
  - "Aligning menubar and CLI output/behavior."
---

# bars CLI

A lightweight Commander-based CLI that mirrors the menu bar app’s provider fetchers and config file.
Use it when you need usage numbers in scripts, CI, or dashboards without UI.

## Install
- In the app: **Preferences → Advanced → Install CLI**. This symlinks `BarsCLI` to `/usr/local/bin/bars` and `/opt/homebrew/bin/bars`.
- From the repo, after installing `bars.app` in `/Applications`: `./bin/install-bars-cli.sh` (same symlink targets; requires macOS administrator approval).
- Manual: `ln -sf "/Applications/bars.app/Contents/Helpers/BarsCLI" /usr/local/bin/bars`.

The bundled macOS CLI identifies its running executable and containing app through the operating system, even
when launched through these symlinks. Mutable external aliases are not added to new credential-cache trust lists.
Existing signature validation, disabled-access settings, and no-prompt rules still apply; standalone development
binaries do not gain access to the app's persistent cache.

The repo installer requires an executable `/Applications/bars.app/Contents/Helpers/BarsCLI`; a missing
helper is an error. It starts the system POSIX shell with `-p` to ignore inherited functions and startup hooks
before helper validation or failure handling. This shell mode does not elevate privileges; macOS administrator
approval is still required. The installer uses absolute system tools, clears the inherited environment before
requesting approval, and stops on installation failure. The in-app installer is separate and uses Foundation symlinks.

## Build
- `./Scripts/package_app.sh` (or `./Scripts/compile_and_run.sh`) bundles `BarsCLI` into `bars.app/Contents/Helpers/BarsCLI`.
- Standalone: `swift build -c release --product BarsCLI` (binary at `./.build/release/BarsCLI`).
- Dependencies: Swift 6.2+, Commander package (`https://github.com/steipete/Commander`).

## Configuration
bars reads the resolved config file for provider settings, secrets, and ordering. New installs use
`~/.config/bars/config.json`; absolute `XDG_CONFIG_HOME` paths and `BARS_CONFIG` are supported, and existing
`~/.bars/config.json` installs keep using the legacy file when no XDG config exists.
See [Configuration](configuration.md) for the schema and [Providers](providers.md) for every registered provider's
sources and setup guide. The [provider ID list](provider-ids.md) is generated from the registry;
`bars config providers` lists providers and their configured enablement without fetching usage.

## Command
- `bars` defaults to the `usage` command.
  - Multi-provider usage fetches run up to three providers concurrently. Text, JSON, and diagnostics retain selection order; a failed provider does not prevent the others from finishing. Refreshed credentials share a command-scoped writer, while externally changed credentials remain protected.
  - `--format text|json|toon` (default: text).
  - Text output and full terminal cards include history already supplied by the selected provider. They preserve the source period, currency, known zero values, and reported/estimated cost labels. This live history remains separate from the ordinary usage JSON schema and the `cost` command.
  - Usage JSON includes optional `resetCredits` with `available` and `nextExpiresAt`, derived from the shared unexpired, available reset-credit inventory. This compact summary contains no credit identifiers; an absent inventory omits the summary.
  - Usage JSON includes optional `rateWindowLabels` for present windows from built-in providers. Consumers can use these display labels when a window omits its cadence; missing windows and unknown provider IDs do not gain invented labels.
  - JSON uses the generic `usage.details` array for provider-specific information. Each section contains an optional
    `title`, `rows` (`label`, `value`, and optional `secondaryValue`), and an optional `bars` or `line` chart. The same
    shape is returned by `GET /usage` from `bars serve`.
  - Clients must read `usage.details`; unknown legacy keys in cached snapshots are ignored when decoding.
  - `--format toon` emits the same payload as `--format json` (and implies `--json`'s credits/no-color behavior),
    rendered as [TOON](https://github.com/toon-format/spec) instead: uniform arrays of scalar-only objects (for
    example `usage.details[].rows`) collapse into a compact `rows[N]{label,value}:` table, everything else falls
    back to an indented list form. This is a presentation-only mapping of the existing JSON schema — no new fields,
    no denormalization — intended for agents that want a token-cheaper alternative to parsing JSON. `usage --format
    toon` is the only command that supports it; every other command still advertises and accepts only
    `--format text|json`, and treats `toon` like any other unrecognized value.
  - Since 0.78.0, Claude usage in Auto follows the active claude-swap slot when the integration is enabled,
    including a single configured slot regardless of `claudeSwapShowSingleAccount`. Earlier versions always used
    the ordinary CLI source order (Web → CLI on macOS), so a browser signed into another account could supply usage.
    The result remains one Claude payload: `source` names the adapter and `usage.accountEmail` / `usage.identity.accountID`
    identify the active slot. Measurement timestamps and any last-known usage diagnostic are preserved.
  - Explicit non-auto `--source` modes, a configured non-auto source, and `--account`, `--account-index`, or
    `--all-accounts` bypass this precedence. Without the integration, source selection is unchanged.
  - If the adapter fails, returns no active slot, or has no usable usage for that slot, the ordinary source order
    still applies. The actual winning source gains ` (claude-swap fallback)` (or ` (tcr fallback)`) in text and JSON,
    and the identity remains that of the fallback account. Another swap slot is never substituted. Pooled tcr
    adapters normally report no active slot and therefore use the labeled fallback.
- `bars cost` prints token cost usage for Claude, OpenCode Go, and Devin.
  - Claude is scanned from local session logs without web/CLI access.
    Text output labels priced results as local estimates and token-only results as token history, and distinguishes unavailable or lower-bound history from a complete period with no recorded usage.
  - `--format text|json` (default: text). `--json` includes the same cost concepts as Settings → Usage & Spend (token mix, `provenance`, coverage), but it is not the dashboard Export JSON schema. CLI places mix fields under each provider's `totals` and emits `provenance`/`coverage` on that provider object; Export JSON nests `tokenMix`, `provenance`, and `coverage` under `groups[]`.
  - Prices come from cached models.dev data with bundled fallbacks; missing usage or price fields remain unknown rather
    than zero. See [model pricing](model-pricing.md).
  - `--refresh` ignores cached scans.
  - `--breakdown` adds Claude-only daily and top-model details to text output. Both sections use the same last seven calendar days (or the shorter requested interval); when that interval has no rows, both explicitly label the latest recorded days. Incomplete attribution is marked partial. Ordinary text, other providers, and JSON output are unchanged.
- `bars cards` prints a one-shot usage snapshot as a responsive terminal card grid.
  - Reuses the same provider, source, account, credits, and status flags as `bars usage`.
  - Account lines and plan badges are included in the card grid by default.
  - `--brief` renders a compact table (Provider / Usage / Reset) instead of the card grid.
  - Stdout is always rendered text; `--json-output` only affects stderr logs (no JSON card payload).
  - Failed providers are summarized in a footer (not rendered as error cards).
  - When the opt-in Claude claude-swap integration returns two or more accounts—or one account with
    `claudeSwapShowSingleAccount` enabled—cards renders every account in active-first/slot order instead of the
    ambient or token-account Claude cards. This includes an explicit
    `--provider claude`; `--source auto` remains eligible.
  - `--account`, `--account-index`, `--all-accounts`, and explicit non-auto source flags preserve their requested
    ambient behavior and do not invoke claude-swap. Zero-account lists always retain ambient Claude output;
    one-account lists do so unless `claudeSwapShowSingleAccount` is enabled.
  - claude-swap sentinel accounts remain successful cards with their problem text and no fabricated usage metrics.
    A list adapter, parser, or timeout failure retains useful ambient Claude output, adds a distinct
    `Claude (claude-swap)` failure footer entry, and makes the command exit non-zero.
  - Cards expands swap accounts; `bars usage` returns only the active slot as described above.
    `bars serve` keeps its existing `/usage` behavior.
  - Honors `$COLUMNS` for layout; falls back to 80 columns. Use `--no-color` for plain output.
  - Kitty, Ghostty, WezTerm, and other truecolor terminals auto-enable enhanced gradients/outlines.
  - Force enhanced mode elsewhere with `BARS_CARDS_ENHANCED=1`.
  - Exit code is non-zero when any provider fetch fails.
- `bars dashboard` prints one dashboard-v1 JSON snapshot and exits.
  - Honors enabled providers in stable order, carries configured display sort keys, and defaults to full account identity; `--identity redacted` hides email local parts.
  - Provider failures remain row-level errors alongside healthy rows; a valid partial snapshot exits `0`.
  - Stdout contains only the snapshot document. Diagnostics and optional `--json-output` logs go to stderr.
  - `--pretty` formats the document. `--timeout <seconds>` accepts `0...86400`, defaults to `30`, and uses `0` to disable the command deadline.
  - `--output <path>` atomically writes the snapshot to a file (`0644`) instead of stdout — staged in the destination directory, fsync'd, then renamed over the target so readers never observe a partial document. The parent directory must already exist (it is not created), and stdout stays silent on success.
  - Starts no HTTP server and requires no dashboard bearer token. See `docs/dashboard-api.md` for the shared payload contract.
- `bars serve` starts a foreground HTTP server for usage and cost JSON, a token-gated dashboard snapshot, and a built-in web UI at `/`.
  - `--all-accounts` expands configured token accounts in dashboard snapshots, with neutral numbered labels, no identity and generic errors by default. Explicit `--identity full` includes identifying details; `--identity redacted` exposes only masked emails/plan labels, not account aliases or raw errors. It is a startup opt-in, not a query parameter; `/usage` and `/cost` are unchanged.
  - `GET /accounts` and `GET /accounts/<id>` discover saved provider token accounts without fetching usage or exporting credentials. IDs are stable opaque lookup keys; `active` means the configured selection. Discovery includes saved accounts for disabled providers, excludes system/profile-home discovery, follows the same identity setting, and requires bearer authentication on non-loopback binds. See [account discovery](dashboard-api.md#account-discovery).
  - Web usage bars follow the app's **Usage bars fill** setting, read per request on macOS. Dashboard snapshots from
    both `serve` and `bars dashboard` expose it as `host.usageBarsShowUsed`. An absent setting defaults to remaining
    percentages; earlier web dashboards always showed used percentages. Quota values are unchanged.
  - Without `--all-accounts`, dashboard snapshot identity follows the app's "Hide personal information" setting when `--identity` is absent: the toggle on redacts email local parts, off keeps full emails. The setting is read per request, so a change applies without a serve restart. Pass `--identity redacted` or `--identity full` to pin the mode and ignore the app setting, especially when responses cross a network.
  - `--host <host>` accepts `localhost` or an IPv4 address and defaults to `127.0.0.1`; `localhost` is normalized to `127.0.0.1`. Binding a non-loopback host requires a dashboard token **and** `--allow-plain-http` (see `docs/dashboard-api.md` for the threat model).
  - `--port <port>` defaults to `8080`.
  - `--refresh-interval <seconds>` defaults to `60` and controls the in-memory response cache TTL.
  - `--request-timeout <seconds>` defaults to `30` and bounds each request before returning `504 Gateway Timeout`; use `0` to keep waiting indefinitely. Slow builds continue past the deadline, commit their finished result to the cache, and feed any same-config request already waiting so a 504 self-heals on retry.
  - `--dashboard-token <token>` sets the static bearer token for `GET /dashboard/v1/snapshot`. Prefer the `BARS_DASHBOARD_TOKEN` environment variable (it wins over the flag; a flag value leaks via `ps`). Empty or whitespace-only tokens are startup errors. Without a token the snapshot route fails closed with `401`.
  - On a **non-loopback** host the token gates **all data routes** — `/usage`, `/cost`, and `/dashboard/v1/snapshot` all require `Authorization: Bearer YOUR_TOKEN`, so account data is never exposed to the network unauthenticated. The static web UI at `/` and `/health` are always open. On the default loopback bind, `/usage` and `/cost` stay unauthenticated.
  - `--allow-plain-http` is the explicit acknowledgment that the bearer token crosses the network **in cleartext on every request** when serving on a non-loopback host. `serve` refuses to start on a non-loopback host without it.
  - Provider config is reloaded for each usage/cost request; cache entries are keyed by the loaded config so provider toggles and source changes do not require restarting `serve`.
  - Transient refresh failures fall back to the last good response for up to ten refresh intervals (minimum five minutes) so polling clients do not flicker between data and errors; disabled when `--refresh-interval 0`.
  - After a cached usage or cost response expires, `serve` returns the last-good response immediately while rebuilding it in the background. Dashboard snapshots wait for a rebuild after their normal refresh interval, including when returning to a previously cached used/remaining mode; request deadlines and last-good fallback on failure still apply. `--refresh-interval 0` keeps every request blocking.
  - The default loopback bind rejects non-loopback `Host` headers; a configured non-loopback `--host` additionally accepts its own name. No CORS, TLS, or daemon mode.
  - Endpoints: `GET /` (web UI), `GET /health`, `GET /usage`, `GET /usage?provider=<id|both|all>`, `GET /cost`, `GET /cost?provider=<id|both|all>`, `GET /dashboard/v1/snapshot` (plus `provider=<id>` and `detail=<full|shell>`).
  - `GET /dashboard/v1/snapshot` requires `Authorization: Bearer YOUR_TOKEN`; responses (and all `401`s) carry `Cache-Control: no-store`. The token is never accepted via query string. See `docs/dashboard-api.md` for the payload contract.
  - `GET /health` returns `{"status":"ok"}` plus a `version` field with the running build (e.g. `"0.37.2"`) when resolvable; clients can compare it against `bars --version` to detect a `serve` process still running an older binary after an update.
- `bars cache clear` clears local bars caches.
  - `--cookies` removes cached browser-cookie headers from the bars Keychain cache.
  - `--cookies --provider <id>` removes browser-cookie cache entries for that provider.
  - `--cost` removes local cost-usage scan caches.
  - `--all` clears both cookies and cost caches. `--provider` is cookie-only and cannot be combined with `--cost` or `--all`.
- `bars cookie refresh` ignores the provider's current cookie caches while importing a replacement through its web strategy. A failed or interrupted import leaves existing cookies intact.
  - Choose exactly one of `--provider <id>` or `--all`; provider support comes from shared browser-cookie metadata rather than a fixed CLI list.
  - Prompt-capable Chromium imports require `--allow-keychain-prompt`. Without it, the command fails before cache mutation with an interactive-retry hint.
  - Selected-profile providers use only their configured browser for that check. Safari needs no Chromium Keychain acknowledgment; a validated nonpersistent refresh succeeds without storing cookies.
  - A six-hour Keychain-denial cooldown also applies to menu and settings Refresh actions; only that explicit acknowledgment flag bypasses it. The command shares one interactive browser read across its selected providers. Output never includes cookie values.
  - Classified provider failures distinguish rejected sessions, permissions, rate limits, outages, network errors, and unreadable responses. Missing credentials retain the browser sign-in hint; disabled or denied Keychain access takes precedence. Hints never echo raw provider error messages.
  - Providers configured for Manual or Off cookie sources are skipped.
- `bars guard --provider <id>` gates automation on one provider's remaining quota.
  - `--min-remaining <percent>` sets the inclusive threshold (default: `10`; valid range: `0...100`).
  - `--window session|weekly` selects the primary/session window or secondary/weekly window (default: `session`).
  - `--timeout <seconds>` bounds the complete fetch (range: `0...86400`; default: `60`; `0` disables this guard-level deadline while provider-specific timeouts still apply).
  - `--json` emits the provider, window, remaining quota, threshold, decision, unavailable reason, and exit code; add `--pretty` for formatted JSON.
  - Stable guard exit codes: `0` means safe, `1` means below threshold, `64` (`EX_USAGE`) means invalid arguments, and `69` (`EX_UNAVAILABLE`) means the quota could not be checked or the selected window is unavailable. `--fail-open` changes only unavailable results from `69` to `0`; JSON still reports `decision: "unknown"` and the reason.
  - Guard fetches are read-only and use background interaction policy, matching `bars usage`; they never request interactive Keychain access.
- `--provider <id|both|all>` (default: enabled providers in config; falls back to defaults when missing).
  - Accepts raw IDs from `bars config providers --format json` as well as CLI names and aliases. Existing CLI names and aliases take precedence if names overlap.
  - Use a registered [provider ID](provider-ids.md) or CLI alias. Enabled providers and ordering live in the config file.
  - With three or more providers enabled, the default stays scoped to enabled providers; use `--provider all` to query
    every registered provider.
  - `--account <label>` / `--account-index <n>` / `--all-accounts` (token accounts from config; requires a single provider).
  - `--no-credits` (hide credits in text output).
  - `--pretty` (pretty-print JSON).
  - `--status` (fetch provider status pages and include them in output).
- `--source <auto|web|cli|oauth|api>` (default: `auto`).
    - `auto`: provider-specific fallback order from `docs/providers.md`.
    - `web`: web-only where that provider exposes an explicit web source; no CLI/API fallback.
    - `cli`: CLI/local-helper source where the provider exposes one (for example Claude PTY or local probes).
    - `oauth`: OAuth-backed source where supported (Claude).
    - `api`: API-backed flow where supported; credentials may be API keys or existing tokens. See the complete [provider source table](providers.md#fetch-strategies-current) and each provider's guide for supported modes.
    - Output `source` reflects the strategy actually used (`web`, `oauth`, `api`, `local`, `cli`, `claude-swap`, `tcr`, or provider CLI label; `bars-app` with `ageSeconds` when SSH falls back to the app's cache, see [SSH sessions](#ssh-sessions-macos)).
    - `--web-timeout <seconds>` (default: 60) and `--web-debug-dump-html` (writes HTML snapshots to `/tmp` when data
      is missing) apply to web sources.
    - Claude web: claude.ai API (session + weekly usage, account metadata, and prepaid Usage credits balance when
      available).
      CLI Auto falls back to the installed Claude executable when web credentials are unavailable. This foreground
      command delegates authentication to Claude Code; the app keeps its stricter prompt-free background availability
      gate for scheduled refreshes.
    - OpenCode Go auto: local SQLite cost history with API usage-window enrichment when
      `OPENCODE_API_KEY` is configured, plus legacy manual-cookie web fallback.
- Global flags: `-h/--help`, `-V/--version`, `-v/--verbose`, `--no-color`, `--log-level <trace|verbose|debug|info|warning|error|critical>`, `--json-output`, `--json-only`.
  - `--json-output`: JSONL logs on stderr (machine-readable).
  - `--json-only`: suppress non-JSON output; errors become JSON payloads.
- `bars config validate` checks the resolved config file for invalid fields.
  - `--format text|json`, `--pretty`, and `--json-only` are supported.
  - Warnings keep exit code 0; errors exit non-zero.
- `bars config dump` prints normalized config JSON with secrets redacted by default. `--show-secrets` explicitly includes raw credentials; `--pretty` formats the output.
- `bars hooks list` shows the local hook configuration; `--format json` and `--pretty` are supported.
- `bars hooks enable|disable` changes the explicit top-level opt-in switch in the local config file.
- `bars hooks test <event> --provider <id>` invokes matching enabled rules with a representative event. Hook
  commands run directly without a shell and receive `BARS_*` variables plus JSON on stdin. `--format json` and
  `--json-only` return structured per-rule results. See
  `docs/configuration.md#external-event-hooks` for the event, payload, timeout, and security contract.
- The macOS app and `hooks watch` emit `usage_updated` after a successful current refresh, throttled to at most
  one attempt per 600 seconds for each provider/account. Its primary and secondary positional quota windows include their cadence in
  minutes. Synthetic placeholder windows are omitted.
- `bars hooks watch` polls enabled providers and fires matching hooks on real quota and status transitions.
  Without it, hook rules only ever fire from the macOS app, so a headless install can configure hooks that never run.
  - `--interval <seconds>`: poll period. Default `300`, minimum `60`; a smaller value is rejected rather than
    clamped, because each tick fetches every selected provider.
  - `--provider <id|both|all>`: restrict polling; repeatable. Defaults to every enabled provider. `both` selects the primary providers; `all` selects every registered provider, including providers not enabled in the config.
  - `--format json`/`--json`/`--pretty`: emit each attempted event as JSON, excluding throttled candidates.
  - Events are edge-triggered against the previous poll, so a condition that merely persists (a saturated window,
    an ongoing outage) does not re-fire every tick. State is in-memory only: a restart re-establishes baselines and
    the first poll establishes each lane's transition baseline. A successful first poll can immediately attempt
    `usage_updated`. Repeated attempts within 600 seconds are dropped, including after command failure; no latest-value
    queue or trailing delivery is scheduled. Private account throttle keys are never included in event payloads.
  - Run `watch` as one continuous process. Repeated one-shot invocations cannot preserve transition baselines or event
    rate limits between polls.
  - Runs read-only, like `bars guard`: it never prompts for credentials. A failed refresh reports
    `refresh_failed` with a coarse category (`timeout`, `offline`, `auth_required`, `network_error`) and never
    forwards the raw provider error.
  - Stops cleanly on `SIGINT`/`SIGTERM`/`SIGHUP`.

### Token accounts
The CLI reads multi-account tokens from the same resolved config file as the app.
- Select a specific account: `--account <label>` (matches the label/email in the file).
- Select by index (1-based): `--account-index <n>`.
- Fetch all accounts for the provider: `--all-accounts`.
Account selection flags require a single provider (`--provider claude`, etc.).
For Claude, token accounts accept either `sessionKey` cookies or OAuth access tokens (`sk-ant-oat...`).
OAuth usage requires the `user:profile` scope; inference-only tokens will return an error.

### Cost JSON payload
`bars cost --format json` emits an array of payloads (one per provider).

The saved app reporting period applies by default. `--period month-to-date|all` selects a calendar month or available source history; `--days N` always overrides it with rolling days. `/cost` follows the saved selection without restarting the server. See [cost reporting periods](cost-reporting-periods.md).

- `reportingPeriod`, `historyLabel`: semantic selection and its display label; `totals` describes that selected window.
- `provider`, `source` (`local` for log scans), `updatedAt`
- `sessionTokens`, `sessionCostUSD`
- `last30DaysTokens`, `last30DaysCostUSD`: for histories longer than 30 days, totals for the latest 30 local calendar dates ending at `updatedAt` (today and the preceding 29 days). Histories of 30 days or fewer retain their available/requested-history totals. Missing amounts remain unavailable.
- `historyCoverageIsEstablished`: `true` when the displayed history covers the requested window, including an established same-scope snapshot retained while a newer bounded scan catches up; `false` when only incomplete history is available.
- `daily[]`: `date`, `inputTokens`, `outputTokens`, `cacheReadTokens`, `cacheCreationTokens`, `totalTokens`, `totalCost`, `modelsUsed`, `modelBreakdowns[]` (`modelName`, `cost`)
- `totals`: `inputTokens`, `outputTokens`, `cacheReadTokens`, `cacheCreationTokens`, `totalTokens`, `totalCost`. These totals and `daily[]` retain the full requested window described by `historyDays`.
- Claude preliminary proxy records without final usage are excluded from totals. A positive optional `incompleteRequestCount` appears on the provider, `totals`, affected `daily[]`, and affected `modelBreakdowns[]`; complete-only payloads keep their previous shape. Known amounts remain partial subtotals, while incomplete-only amounts stay unavailable. Text output and the web dashboard mark these subtotals **Incomplete**. Usage & Spend exports include the same optional count on affected currency groups, providers, and model rows.
- `error`: structured provider error when a fetch fails (for example a provider requested while its cookie source is Off).

## Manage the HTTP server from the Mac app

In **Settings → Advanced → HTTP server**, enable the server, generate a token,
and click **Apply**. Defaults are off, `127.0.0.1:8080`, a 60-second cache,
a 30-second request timeout, and redacted dashboard identity. Apply saves the settings
and restarts only the app's own bundled CLI helper. A terminal-started server is
independent; a port conflict appears as a startup failure in Settings.

For a phone or another device, bind to the Mac's VPN/Tailscale IPv4 address, or
`0.0.0.0` to listen on every IPv4 interface. Non-loopback listening requires a token
and explicit acceptance of unencrypted HTTP. The server exposes usage, cost, account and
project information, never provider credentials. Dashboard identity controls affect
account discovery and snapshots; `/usage` and `/cost` retain their CLI payloads. The token is a credential for that
information: anyone holding it can read those endpoints. Use an encrypted VPN or
Tailscale connection; do not expose this HTTP listener directly to the internet.
When binding `0.0.0.0`, replace that address in the copied URL with the Mac's actual
VPN/Tailscale address on the remote device.

Open the copied dashboard URL in the phone's browser and enter the token. API clients
send `Authorization: Bearer <token>` to `/usage`, `/cost`, or
`/dashboard/v1/snapshot`; no provider login is needed on the remote device. The Mac
must remain awake with bars running. Quitting bars stops its managed server;
reopening starts it again if enabled. **Show**, **Generate**, and **Copy** manage the
token locally. After generating a replacement, click Apply and update your clients.
The token and server settings live in the owner-only `http-server.json` beside the
app's resolved provider config, outside bars's settings export payloads.

The built-in server speaks HTTP, not HTTPS. An iOS app may need an explicit App
Transport Security policy for a trusted VPN HTTP endpoint. For HTTPS, use a separately
configured TLS reverse proxy and a certificate trusted by the device (publicly trusted,
or a self-signed certificate explicitly installed and trusted). Keep bearer
authentication enabled through that proxy. A proxy forwarding to loopback must expose
only token-gated dashboard routes, or enforce its own authentication for `/usage` and
`/cost`, which remain unauthenticated on loopback. This setting does not install certificates,
configure a proxy, or change the behavior of a separate `bars serve` command.

## Example usage
```
bars                          # text, respects app toggles
bars --provider claude        # force Claude
bars --provider all           # query all registered providers
bars --format json --pretty   # machine output
bars --format json --provider both
bars cost                     # saved app period, otherwise 30 days + today
bars cost --period month-to-date --json
bars cost --period all --json
bars cost --days 90           # choose a 1...365 day cost window
bars cost --provider claude --format json --pretty
bars guard --provider claude --min-remaining 20 --window weekly --json
bars dashboard | jq '.providers[] | {id, windows, error}'
bars serve --port 8080        # localhost HTTP JSON server
bars serve --request-timeout 0 # disable serve request deadlines
BARS_DASHBOARD_TOKEN=YOUR_TOKEN bars serve # token-gated dashboard snapshot
BARS_DASHBOARD_TOKEN=... bars serve --host 0.0.0.0 --allow-plain-http # LAN, cleartext accepted
bars --status                 # include status page indicator/description
bars --provider claude --source oauth --format json --pretty
bars --provider claude --source web --format json --pretty
bars --provider claude --account user@example.com
bars --provider claude --all-accounts --format json --pretty
bars --json-only --format json --pretty
DEEPSEEK_API_KEY=... bars --provider deepseek --source api --format json --pretty
bars config validate --format json --pretty
bars config dump --pretty
printf '%s' "$ANTHROPIC_ADMIN_KEY" | bars config set-api-key --provider claude --stdin
bars config enable --provider devin
bars config set-source --provider claude --source cli
bars config set-source --provider claude --source auto
bars cache clear --cookies
bars cache clear --cookies --provider claude
bars cache clear --all --format json --pretty
bars cookie refresh --provider opencodego --allow-keychain-prompt
```

`config set-source` writes the provider's `source` in the resolved config file, using the same
store as Settings. It accepts the provider names and aliases used by `config enable`, and rejects
sources not offered by that provider's fetch plan. `--source auto` removes the override. Provider
enablement, credentials, and other config fields are preserved. JSON output includes `provider`,
`displayName`, `enabled`, `source`, and `configPath`; `source` reports `auto` after clearing an override.
Invalid arguments are rejected before reading or writing the config, leaving any existing file byte-identical.
Successful writes use the shared store's normal defaults and JSON formatting; setter output contains no credentials.

### Sample output (text)
```
== Claude Code 2.0.58 (web) ==
Session: 88% left [==========--]
Pace: On pace | Expected 13% used | Lasts until reset
Resets tomorrow at 1:00 AM
Weekly: 63% left [=======-----]
Pace: On pace | Expected 37% used | Runs out in 4d
Resets Sat at 6:00 AM
Sonnet: 95% left [===========-]
Account: user@example.com
Plan: Pro

```

### Sample output (JSON, pretty)
```json
{
  "provider": "claude",
  "version": "2.0.58",
  "source": "web",
  "status": { "indicator": "none", "description": "Operational", "updatedAt": "2025-12-04T17:55:00Z", "url": "https://status.claude.com/" },
  "usage": {
    "primary": { "usedPercent": 12, "windowMinutes": 300, "resetsAt": "2025-12-05T01:00:00Z" },
    "secondary": { "usedPercent": 37, "windowMinutes": 10080, "resetsAt": "2025-12-06T06:00:00Z" },
    "tertiary": null,
    "updatedAt": "2025-12-04T18:10:22Z",
    "identity": {
      "providerID": "claude",
      "accountEmail": "user@example.com",
      "accountOrganization": null,
      "loginMethod": "Pro"
    },
    "accountEmail": "user@example.com",
    "accountOrganization": null,
    "loginMethod": "Pro"
  },
  "pace": {
    "primary": { "stage": "onTrack", "deltaPercent": 0, "expectedUsedPercent": 13, "willLastToReset": true, "summary": "On pace | Expected 13% used | Lasts until reset" }
  }
}
```

## Exit codes
- 0: success
- 2: provider missing (binary not on PATH)
- 3: parse/format error
- 4: CLI timeout
- 1: unexpected failure

For `bars dashboard`, `0` includes a valid partial snapshot whose provider rows contain errors. The command exits
non-zero only when it cannot produce a valid snapshot document.

## Notes
- CLI uses the config file for enabled providers, ordering, and secrets.
- CLI binary discovery checks explicit overrides, captured login PATH, inherited PATH, and known install paths before falling back to an interactive shell probe.
- Automatic executable discovery and child PATHs use absolute directories only; empty, `.` and relative entries are ignored. Install CLIs in an absolute PATH directory. Explicit executable overrides and shell startup files remain trusted user configuration.
- Bundled helpers and resources are located relative to the resolved running executable, including symlinked CLI installations, rather than the invocation directory.
- Shell discovery drains stdout and stderr within its existing timeout, but rejects incomplete captures and stdout larger than 1 MiB instead of parsing a truncated path. Keep shell startup output quiet if automatic binary discovery fails.
- Reset lines follow the in-app reset time display setting when available (default: countdown).
- Text output uses ANSI colors when stdout is a rich TTY; disable with `--no-color` or `NO_COLOR`/`TERM=dumb`.
- Claude Admin API charts require an Anthropic Admin API key (`sk-ant-admin...` or `ANTHROPIC_ADMIN_KEY`).
- Claude CLI `auto` tries web, then CLI PTY; the app’s Claude `auto` path prefers OAuth, then CLI, then web.
- Web sources require a signed-in session in a supported browser or a manual cookie header. No passwords are stored; bars reuses cookies.
- Safari cookie import may require granting bars Full Disk Access (System Settings → Privacy & Security → Full Disk Access).

## SSH sessions (macOS)

When the login keychain is locked, keychain-backed providers can fail over SSH while the app has fresh
numbers. Set `"shareUsageWithCLI": true` in `config.json` (off by default) and the app writes a private cache
(`~/Library/Application Support/bars/CLIUsageCache/usage.json`, `0600` in a `0700` directory) holding rate
windows (including extra quota rows) and fetch times, without credentials, costs, or account identity. Provider-supplied text such as reset descriptions and
window titles is stored as received. In a non-GUI session, when a default-account
fetch without `--source` hits a locked keychain and ends with a missing-credential or cookie-access error (for example
`No Claude session key found in browser cookies.`), `usage` and `cards` report the app's
numbers instead (at most one hour old) as `"source": "bars-app"` with `"ageSeconds"` (whole seconds since the app fetched them). Other failures (timeouts, parse errors, HTTP rejections), token
accounts, explicit account selections, and GUI sessions keep their normal behavior.
Future-dated, corrupt, incorrectly owned, non-private, and symlinked cache files are ignored. Disabling sharing removes
the file; providers that no longer have an eligible default-account snapshot are withdrawn on the next publication.
