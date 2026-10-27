---
summary: "Agent Sessions discovery, protocol versions, presentation, and privacy boundaries."
read_when:
  - Changing local or SSH agent-session discovery
  - Reviewing Agent Sessions architecture
---

# Agent Sessions design

bars discovers Claude Code sessions locally and over SSH. Local discovery correlates processes with bounded
metadata.

## Data model

`AgentSession.Provider` contains only `claude`. A resolved upstream session ID is preferred, while an unmatched
process uses `pid:<pid>`.

`bars sessions --json` emits a top-level array. Remote fetching runs `sessions --json` on the target host.

## Local scanner

`LocalAgentSessionScanner` combines bounded process and metadata signals. Process and cwd discovery stays
in-process through libproc.

Claude bundle checks, provider identity, and CLI/desktop source labels use the preserved executable argument, so
prompt paths do not change session classification. Existing executable allowlists, wrapper handling, and
command-only fallbacks still apply.

Claude transcript scans have their own bounded directory entry/time budget. Header reads are bounded, future
modification dates are clamped to scan time, and displayed titles are stripped of control characters and limited to
64 Unicode scalars. The deadline also gates file-type inspection and queued Claude Desktop root probes. In-flight
filesystem calls can finish after the deadline; this is a best-effort work budget, not an interruptible timeout.

## Presentation and focus

The menu marks Claude Code sessions with `✦`. Project labels remain the default because descriptive titles can
contain sensitive text.

Local focus walks from the session PID to the owning terminal/editor application and raises the best matching window
when Accessibility permission is available. Remote focus invokes the same command over SSH.

## Privacy and safety

bars never invokes `ps eww` or otherwise captures full target-process environments for session discovery. It reads only bounded session metadata under resolved roots, never loads prompt/tool transcript bodies for this feature, never changes upstream session state, and never persists extracted titles separately.

## Stay Awake

Settings → Menu → Agent Sessions → **Stay Awake** is off by default and local to this Mac. It scans locally every 30 seconds without enabling the sessions menu or remote discovery. One `PreventUserIdleSystemSleep` assertion stays active while at least one session has a positive PID, including idle processes waiting for a prompt. Remote sessions do not count. The menu shows “Stay Awake: local agent session is live” while active.

The assertion releases at the next scan with no process-backed sessions, immediately on disablement or quit, and through macOS on a crash. Stale scans cannot reacquire it after disablement or shutdown; failed acquisitions retry on the next scan. Stay Awake can use battery power. It cannot wake a Mac or prevent display, explicit, or lid-close sleep, and has no timer, grace period, or always-on mode.

Final store teardown cancels its tasks and releases an owned assertion on the thread that drops the last reference, without a main-actor cleanup hop. Live state changes remain on the main actor; teardown uses Sendable task handles and the thread-safe assertion-release closure.

## Non-goals

Historical browsing/analytics, cloud chat/task sessions, permission-waiting state, exact tmux pane focus, a persistent remote daemon, and treating the upstream on-disk format as a public compatibility guarantee are out of scope.
