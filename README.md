# bars

A small, fast macOS menu bar app that shows how much of your AI coding limits you have left, and when they reset.

bars tracks five providers: Claude, OpenCode, OpenCode Go, Devin, and DeepSeek. It is a hard fork of
[CodexBar](https://github.com/steipete/CodexBar) by Peter Steinberger, trimmed down to those providers and tuned
for speed.

## Providers

- [Claude](docs/claude.md) — OAuth API, browser cookies, or CLI fallback; session and weekly usage, plus local cost estimates from Claude Code logs.
- [OpenCode](docs/opencode.md) — Browser cookies for workspace subscription usage.
- [OpenCode Go](docs/opencodego.md) — Usage API, browser fallback, and local SQLite cost history.
- [Devin](docs/devin.md) — Chrome localStorage session or manual Bearer token for daily and weekly quotas.
- [DeepSeek](docs/deepseek.md) — API key for credit balance (paid vs. granted).

<!-- Generated provider additions: Scripts/regenerate-provider-docs.mjs -->

<!-- End generated provider additions -->

## Features

- One status item per provider, or Merge Icons mode with a provider switcher.
- Usage meters with reset countdowns, pace hints, and optional quota notifications.
- Local cost estimates and spend charts from Claude Code and OpenCode Go history.
- Adaptive refresh by default, with manual and fixed-interval alternatives.
- WidgetKit widgets.
- A bundled `bars` CLI for scripts.
- Localized in 23 languages.
- On-device parsing; browser cookies are opt-in and reused, and no passwords are stored.

## Install

There are no prebuilt releases. Build from source:

```bash
git clone https://github.com/sirrayi/bars.git
cd bars
./Scripts/package_app.sh
open bars.app
```

Requires macOS 14+ and Swift 6.2+ (Xcode or the Command Line Tools). Builds are ad-hoc signed for your own Mac.
To update, pull and run `./Scripts/package_app.sh` again.

Install the CLI after copying `bars.app` to `/Applications`:

```bash
./bin/install-bars-cli.sh
```

### First run

- Open Settings → Providers and enable what you use.
- Sign in to the sources each provider relies on: the Claude CLI or browser session, OpenCode in your browser, Devin
  in Chrome, or a DeepSeek API key.

### Configure from the CLI

Provider toggles and API keys live in `~/.config/bars/config.json`:

```bash
bars config providers
bars config enable --provider devin
printf '%s' "$DEEPSEEK_API_KEY" | bars config set-api-key --provider deepseek --stdin
bars usage --provider all
```

See [CLI configuration](docs/cli-configuration.md) and the [CLI reference](docs/cli.md).

## Privacy

bars does not crawl your disk. It reads a small set of known locations (browser cookies or local storage, provider
config files, and local JSONL logs) only when the related features are enabled. Provider tokens live in the bars
config file with restrictive permissions.

## macOS permissions

- **Full Disk Access (optional)**: only needed to read Safari cookies. Other browsers, manual cookies, API keys, OAuth,
  and CLI sources work without it.
- **Keychain**: Chromium cookie import needs the browser's Safe Storage item, and an explicit Claude OAuth repair may
  read Claude Code's Keychain item. Background work never asks; a user-initiated action can show the macOS prompt.
  Settings → Advanced → Disable Keychain access blocks bars-owned Keychain use. Because builds are ad-hoc signed, macOS
  may ask again after each rebuild. See [Keychain prompts](docs/keychain-prompts.md).
- **Files & Folders**: provider CLIs that bars launches may trigger folder prompts based on their working directory.

## Development

```bash
./Scripts/compile_and_run.sh   # build, package, relaunch
make test-fast FILTER='Suite'  # focused tests
make check                     # lint and repository checks
```

See [Development](docs/DEVELOPMENT.md), [Architecture](docs/architecture.md), [Configuration](docs/configuration.md),
[Refresh loop](docs/refresh-loop.md), [Widgets](docs/widgets.md), and the
[provider authoring guide](docs/provider.md).

## Credits

bars is based on [CodexBar](https://github.com/steipete/CodexBar) by Peter Steinberger. Cost tracking was inspired
by [ccusage](https://github.com/ryoppippi/ccusage).

## License

MIT. See [LICENSE](LICENSE).
