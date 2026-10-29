---
summary: "Refresh cadence, background updates, and error handling."
read_when:
  - Changing refresh cadence, background tasks, or refresh triggers
  - Investigating refresh timing or stale data behavior
---

# Refresh loop

## Cadence
- `RefreshFrequency`: Manual, 1m, 2m, 5m, 15m, 30m, Adaptive (fresh-install default), and
  Adaptive (agent-aware).
- Stored in `UserDefaults` via `SettingsStore`. An unset cadence resolves to Adaptive only when no prior-launch marker
  or existing config is present, and the resolved value is persisted immediately. Existing installations without a
  stored cadence and unrecognized stored values resolve to the legacy 5-minute fallback. Every valid stored choice,
  including Manual and each fixed interval, remains unchanged.

## Behavior
- Background refresh runs off-main and updates `UsageStore` (usage + credits + optional web scrape).
- Manual “Refresh now” always available in the menu.
- Stale/error states dim the icon and surface status in-menu.
- Optional provider-storage scans run only when “Show provider storage usage” is enabled. They are scheduled in the
  background, coalesced/throttled during automatic refreshes, and forced by manual refresh without blocking the usage
  refresh path.
- Explicit Claude OAuth requests retain transport identity through provider-specific diagnostics. Recognized
  temporary network failures keep the last successful snapshot and its original measurement time, and use the
  existing startup-retry and refresh-hook categories even with localized messages. Authentication, source selection,
  and stale-refresh invalidation retain their existing rules; cancellations are suppressed before the
  consecutive-failure gate.

## Adaptive mode
- `AdaptiveRefreshPolicy` (`Sources/Bars/AdaptiveRefreshPolicy.swift`) is a pure function of an `Input`
  (current time, last menu-open time, latest local coding-activity time, Low Power Mode, thermal state) that returns
  the next delay and a stable `Reason`. It reads no clock and no `ProcessInfo` state itself;
  `UsageStore.startTimer()` gathers those impure signals immediately before each tick.
- Policy table, first match wins:

  | Condition | Delay | Reason |
  |---|---:|---|
  | Low Power Mode enabled, or thermal state `.serious`/`.critical` | 30 min | `constrained` |
  | Menu opened at most 5 min ago (including future/clock-adjusted timestamps) | 2 min | `recentInteraction` |
  | Menu opened more than 5 min and at most 1 h ago | 5 min | `warm` |
  | Local Claude transcript activity observed less than 5 min ago, when the menu rule would be slower | 5 min | `codingActivity` |
  | Menu opened 1–4 h ago | 15 min | `idle` |
  | No recorded menu open, or opened 4+ h ago | 30 min | `longIdle` |

- Every decision falls in the 2–30 min range by construction. Deliberately excludes quota, latency, error,
  account, and time-of-day signals.
- `UsageStore` tracks `lastMenuOpenAt` and `lastCodingActivityAt` in memory only (never persisted; both reset on
  launch). A menu open can bring either adaptive mode forward. A newer local activity observation can affect only
  Adaptive (agent-aware); it never affects plain Adaptive, postpones an earlier tick, or refreshes synchronously.
- Adaptive (agent-aware) reuses `LocalAgentSessionScanner` every 30 seconds only after the user allows local coding
  activity. The
  persisted `adaptiveActivityScanConsent` value is `undecided`, `allowed`, or `declined`; missing or invalid values are
  repaired to `undecided`, which never authorizes a scan. Declining selects plain Adaptive; explicitly selecting the
  agent-aware option again asks again.
- An allowed scan inspects running processes and their arguments through native process APIs, resolves working
  directories, and inspects process-gated Claude transcript metadata. bars discards session records when the
  Agent Sessions UI is off and retains only the latest `Date`. Each scan considers at most 64 agent processes, keeps
  at most 64 Claude transcript candidates per project, and shares a 512-entry, depth-1, 150 ms agent-aware directory
  metadata budget. Future transcript mtimes are clamped to one scanner-lifetime timestamp. The clamp retains no file
  paths, and unchanged future-dated files cannot manufacture newer activity every 30 seconds.
  Agent-aware scans pause under Low Power Mode and serious/critical thermal pressure. Explicitly enabling Agent
  Sessions continues to authorize its local scan independently of the Adaptive consent choice. Stay Awake can keep
  its live-process scan running while constrained. Tailscale discovery and SSH remain behind the Agent Sessions
  setting. The activity timestamp is not persisted, logged, or uploaded, and it is cleared when consent is revoked.
  Plain Adaptive does not use this signal, and remote discovery is unchanged.
- Each adaptive tick recomputes the delay after the previous refresh completes, sleeps, then calls the same
  `UsageStore.refresh()` used by fixed-interval mode, so the existing `isRefreshing` coalescing guard still
  applies — only one provider-batch refresh runs at a time regardless of cadence mode.
- Selected delay and reason are logged (e.g. `reason=warm delay=300s` in the `adaptive-refresh` category) through
  the existing local logger; never provider identity, account, email, workspace, path, credentials, or response data.
- Interval-derived heuristics (reset-boundary refresh, persistent-CLI-session idle windows)
  read `UsageStore.normalRefreshIntervalForHeuristics()`, which resolves adaptive mode to the current decision's
  delay — they stay active in adaptive mode rather than degrading to manual, whose interval is nil.
- Reset rollover is independent of cadence, manual included: `UsageStore` wakes at the earliest published reset time
  and rolls every window whose reset has passed, for any provider, over to 0% used with no known reset, keeping the
  snapshot's original "Updated" age. The menu, icon, and widgets therefore stop showing an ended window's
  percentages at the reset itself, even when the reset-boundary refresh fails or is held back; the next successful
  refresh fills in the new window. A published or restored snapshot whose reset already passed rolls over at once.

See also: `docs/status.md`, `docs/ui.md`.
