---
summary: "bars CLI configuration commands for provider toggles, API keys, and isolated config files."
read_when:
  - Using bars config from scripts or CI
  - Enabling or disabling providers without opening Settings
  - Storing provider API keys from the command line
---

# CLI configuration

`bars config` edits the same resolved config file used by the app's Settings → Providers pane.
New installs use `~/.config/bars/config.json`; absolute `XDG_CONFIG_HOME` paths and `BARS_CONFIG` are
supported, and existing `~/.bars/config.json` installs keep using the legacy file when no XDG config exists.
The CLI stages writes in a private `0700` directory on the destination volume, creates the file with `0600` permissions before writing any bytes, then syncs and atomically replaces the config.

## Providers

List persistent provider toggles:

```bash
bars config providers
bars config providers --json --pretty
```

Enable or disable a provider:

```bash
bars config enable --provider devin
bars config disable --provider opencode
```

These are persistent app/CLI settings. They are different from `bars usage --provider devin`, which is a one-shot
command override and does not edit config.

If every provider is disabled, `bars usage` with no `--provider` prints no text output, and
`bars usage --json` prints `[]`. Passing `--provider <name>` still fetches that provider for the one command.

## API keys

API keys are stored under the provider entry in config:

```bash
printf '%s' "$DEEPSEEK_API_KEY" | bars config set-api-key --provider deepseek --stdin
```

`set-api-key` enables the provider by default. Add `--no-enable` when you only want to save the key:

```bash
printf '%s' "$OPENCODE_API_KEY" | bars config set-api-key --provider opencodego --stdin --no-enable
```

Claude also accepts an Anthropic Admin API key for organization spend:

```bash
printf '%s' "$ANTHROPIC_ADMIN_KEY" | bars config set-api-key --provider claude --stdin
```

Only providers that consume config-backed API keys accept this command. Admin API keys need organization/usage
permissions, not a normal inference key.

## Isolated config files

For tests, demos, and CI, point bars at a temporary config file:

```bash
export BARS_CONFIG=/tmp/bars-config.json
bars config enable --provider devin
bars config providers --json --pretty
```

The override applies to both reads and writes for the current process environment.

## Cost history window

The app setting controls the menu's local cost-history window. For one-off CLI reports, pass `--days`:

```bash
bars cost --provider claude --days 180 --format json --pretty
```

The accepted range is 1...365 days.

## Validation

After hand-editing config:

```bash
bars config validate
bars config dump --pretty
```

`dump` prints normalized config, including providers omitted from a hand-written file.

Missing, empty, or JSON-whitespace-only config files use defaults. `validate`, `dump`, and
`usage` leave such files unchanged; the next `config enable`, `disable`, or `set-api-key` writes valid JSON.
Malformed non-empty JSON still produces a config error and a nonzero exit without overwriting the file.
