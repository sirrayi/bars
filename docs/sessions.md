---
summary: "Agent Sessions setup, SSH hosts, refresh behavior, and privacy controls."
read_when:
  - Configuring local or remote Agent Sessions
  - Troubleshooting unreachable session hosts
---

# Agent Sessions

bars can list live Claude Code sessions on this Mac and on other Macs reachable over SSH.

Enable **Settings → Menu → Agent sessions**. Local sessions refresh every 30 seconds. **Remote sessions (Tailscale / SSH)** independently controls discovery and SSH polling; it starts off for new users and preserves remote monitoring for users who already enabled Agent Sessions. Turning it off clears remote rows, cancels polling and leaves local monitoring and Stay Awake active. When enabled, remote sessions refresh every 60 seconds and whenever the menu opens. Tailscale discovery includes online macOS peers; add extra SSH destinations as a comma-separated list, such as `user@host`.

On macOS, sessions remain discoverable from their running process arguments after a CLI update removes the old executable.

SSH usernames retain their case when destinations are deduplicated: `user@host` and `USER@host` are separate
targets. Hostname case alone does not create a duplicate target.

**Hide unreachable hosts** is opt-in and off by default. When enabled, it hides remote hosts after any failed session fetch, including connection, authentication, incompatible CLI, or decoding errors. Fetching and retries continue. Turn it off to restore the `— unreachable` rows and their diagnostic tooltips.

**Agent sessions** itself is off by default. While it is off, bars clears published local and remote session rows and does not fetch remote sessions. Adaptive agent-aware refresh may still collect a local activity timestamp after explicit consent, but it does not retain or publish session identities or paths.

Choose the row label format in the same settings section:

- **Project** keeps the working-directory name used by earlier releases.
- **Descriptive** uses the session or named subagent task when available, with the project as a fallback.
- **Descriptive + project** shows both when they differ.

Session titles can contain sensitive text. **Project** remains the default. bars reads only bounded metadata, limits labels to 64 Unicode scalars, does not modify provider state, and does not persist titles separately.

The menu groups local sessions first, followed by each remote host. A filled dot is active; an empty dot is idle. Select a local row to activate its terminal, editor, or desktop app. The first focus attempt can request macOS Accessibility permission so bars can raise the matching window. Remote rows run the same focus command over SSH.

The CLI exposes the same scanner:

```console
bars sessions
bars sessions --json
bars sessions focus <session-id>
```

`bars sessions --json` emits a top-level array of sessions. Dates use ISO 8601.

Remote fetching runs `sessions --json`, first through `bars` on `PATH` and then through the bundled app CLI.

Remote hosts need key-based, non-interactive SSH and either `bars` on `PATH` or bars installed in `/Applications`.

Tailscale discovery runs `tailscale status --json` only through a standalone compiled CLI found on PATH, `/usr/local/bin`, or `/opt/homebrew/bin`. It never executes a macOS app-bundle binary, a symlink into a bundle, or a launcher script: those can start the VPN even for a status query. With only the App Store app or its CLI wrapper installed, discovery is skipped with a diagnostic in the debug log; explicitly configured SSH hosts still work when remote sessions are enabled. The standalone CLI's [status command](https://github.com/tailscale/tailscale/blob/v1.104.1/cmd/tailscale/cli/status.go) reads the daemon's [status endpoint](https://github.com/tailscale/tailscale/blob/v1.104.1/client/local/local.go#L805) without requesting a tunnel start.
