---
summary: "Development workflow: build/run scripts, logging, and keychain migration notes."
read_when:
  - Starting local development
  - Running build/test scripts
  - Troubleshooting Keychain prompts in dev
---

# bars Development Guide

## Quick Start

### Building and Running

```bash
# Full build, package, and launch (recommended)
./Scripts/compile_and_run.sh

# Also run the sharded test suite before packaging/relaunching
./Scripts/compile_and_run.sh --test

# Just build and package (no tests)
./Scripts/package_app.sh

# Launch existing app (no rebuild)
./Scripts/launch.sh
```

### Development Workflow

1. **Make code changes** in `Sources/Bars/`
2. **Run** `./Scripts/compile_and_run.sh --test` to test, rebuild, and launch
3. **Check logs** in Console.app (filter by "bars")
4. **Optional file log**: enable Debug → Logging → "Enable file logging" to write
   `~/Library/Logs/bars/bars.log` (verbosity defaults to "Verbose")

## Localized countdowns

`UsageFormatter.resetCountdownDescription` returns a complete relative phrase. Use `resetCountdownDuration` inside sentences that already include a preposition, such as “Runs out in %@”. Countdown wrappers such as “Regenerates %@” and “Expires %@” receive the complete relative phrase; keep their grammar without repeating its time words. Countdown units come from each language’s existing abbreviated templates; Ukrainian uses `дн.`, `год`, and `хв`, which do not require plural inflection. Keep widget catalogs generated from the app catalogs with `node Scripts/sync-widget-locales.mjs`.

## Swift Toolchain Compatibility

CI builds and tests with Xcode 27 only, on GitHub's `xcode-27` image. Older
toolchains (the former Xcode 26.3 / macOS 15 compatibility build) are no longer
verified; the package manifest still declares Swift tools 6.2, but builds with
older Xcode releases are best effort.

Keep large initializer and `#expect` expressions simple: bind intermediate values
to explicitly typed locals when the type checker struggles. Use
`ProviderColor(hex:)` for provider colors instead of arithmetic inside spec initializers.

## Keychain Prompts (Development)

### First Launch After Fresh Clone
bars does not run a prompt-capable startup Keychain migration. Unified config migration reads retired stores and
clears them only after every source was readable and the new config was persisted. If a source is unreadable, cleanup
and migration completion are deferred to a later launch.

### Subsequent Rebuilds
Ad-hoc development builds can still prompt for browser or provider-owned items because their code-signing identity is
not stable. Use a consistently signed packaged bundle for intentional live credential validation. Routine tests must
use the repository's suppression-safe test harness and never query the real Keychain.

### Why This Happens
- Keychain access control checks the executable's code signature and designated requirement.
- Ad-hoc builds and changed identities may no longer match an existing grant.
- Chromium and provider apps can rotate or recreate their foreign-owned items, replacing prior grants.
- `ThisDeviceOnly` accessibility controls item availability and syncing; it does not repair a code-signature ACL
  mismatch or prevent authorization prompts.

See [Keychain prompts](keychain-prompts.md) for the current user-facing boundary and safe troubleshooting.

## Project Structure

Key source, test, and packaging paths (not exhaustive):

```
bars/
├── Sources/Bars/          # Main app (SwiftUI + AppKit)
│   ├── BarsApp.swift      # App entry point
│   ├── StatusItemController*.swift  # Menu bar icon, menu rendering, and actions
│   ├── UsageStore*.swift      # Usage refresh, caching, widgets, and history
│   ├── SettingsStore*.swift   # User preferences and config persistence
│   ├── Providers/             # App-side provider settings/runtime glue
│   └── Resources/             # Assets and localized strings
├── Sources/BarsCore/      # Shared business logic used by app, CLI, and widgets
│   ├── Config/                # Config file model, reader, writer, and validation
│   ├── Providers/             # Provider descriptors, fetchers, parsers, and status probes
│   └── Vendored/              # Embedded support code
├── Sources/BarsCLI/       # Bundled bars command-line tool
├── Sources/BarsWidget/    # WidgetKit support
├── WidgetExtension/           # Xcode wrapper for the packaged widget extension
├── Tests/BarsTests/       # macOS app/core test suite (XCTest + Swift Testing)
└── Scripts/                   # Build and packaging scripts
```

## Common Tasks

### Add a New Provider
See the canonical [provider authoring guide](provider.md#adding-a-new-provider) for the complete flow.

1. Add the provider identity to `Sources/BarsCore/Providers/Providers.swift`.
2. Add the descriptor and the fetcher, parser, settings-reader, or status-probe pieces the provider needs under
   `Sources/BarsCore/Providers/YourProvider/`.
3. Follow the descriptor naming convention in the provider authoring guide.
4. Add an app-side `ProviderImplementation` under `Sources/Bars/Providers/YourProvider/`; implementations can use
   protocol defaults when no custom UI or macOS integration is needed.
5. Run `Scripts/regenerate-provider-manifests.sh` to update the Core descriptor manifest and the immutable app catalog.
6. Add icon assets under `Sources/Bars/Resources/`.
7. Add focused tests under `Tests/BarsTests/`.

### Debug Cookie Issues
1. Enable Debug → Logging → "Enable file logging" or raise verbosity in the app settings.
2. Reproduce with `./Scripts/compile_and_run.sh`.
3. Check logs in Console.app:
   - Filter: `subsystem:com.sirrayi.bars`

### Debug Menu Bar Placement

Status-item creation checks the item's saved preferred position and its matching legacy key before assigning the
autosave name. Malformed, non-finite, non-positive, and out-of-bounds positions are removed; unrelated items are
untouched, and each removed key is logged. The bound is the widest connected display's width in points plus a
512-point margin, independent of display arrangement. Finite positive positions are preserved when no display bound
is available. Unlike the older global-coordinate bound, this also clears menu-manager parking positions beyond that
range. Preferred-position repair runs on each creation, independently of the one-time hidden-visibility repair flag.
Items are created with zero length, assigned their stable autosave name, registered, then given variable length.
Startup, provider vending, and visibility recovery all use this synchronous factory; recovery keeps `bars-merged`.
Dictionary-backed placement tests and a recording item cover cleanup and creation order without creating live status
items. AppKit exposes no public factory taking an autosave name, so zero-length creation cannot prove how a menu
manager enumerates an item inside AppKit's factory. These tests also do not establish the writer of a position that
changes after launch; recurring placement and Bartender UUID behavior still require isolated runtime evidence.

Runtime removal and visibility changes preserve the current saved position if AppKit clears it. Runtime removal
hides the item under its stable name, removes it with that name intact, then retires the autosave identity to prevent
later cleanup from clearing the restored position. This includes startup visibility recovery when Control Center
has not hosted the items yet: resetting a visible item's name before removal exposes a new automatic identity to
menu bar managers. Replacement items keep the existing `bars-merged` and `bars-<provider>` names. During
`applicationWillTerminate`, removal instead keeps the identity intact: renaming a host immediately before exit can
leave a blank Control Center slot on macOS 26.6.2. Status-menu Quit requests termination after menu tracking unwinds
and leaves cleanup to that callback; shutdown detaches menus without hiding or renaming the items before removal.
The deterministic tests use in-memory defaults, an injected recording status bar, and a hosting probe that misses
the first startup sample to check recovery and teardown ordering, identity, visibility, and placement restoration.
They compare already-hosted relaunches with delayed hosting; they do not reproduce Bartender's UUID store.
Native proof must use a signed, isolated app with visibly hosted
merged and provider items: record the exact old window IDs, quit normally, confirm those windows disappear, then
relaunch and check custom positions. Also exercise runtime removal/recreation and hide/show. Unit tests cannot prove
Control Center host removal or placement after process exit. This does not diagnose older out-of-range placement reports.

### Run Tests Only

The shell test runners and all Make test targets source `Scripts/test_environment.sh` before launching Swift.
It removes exported variables whose names contain `TOKEN`, `KEY`, `SECRET`,
`PASSWORD`, `PASSWD`, `WEBHOOK`, `CREDENTIAL`, `COOKIE`, `PRIVATE`, or `_PAT`, ignoring case. Explicit non-secret
exceptions preserve `BARS_ALLOW_TEST_KEYCHAIN_ACCESS`, `BARS_SUPPRESS_TEST_KEYCHAIN_ACCESS`,
`BARS_DISABLE_KEYCHAIN_ACCESS`, and `BARS_USE_LOCAL_SWEETCOOKIEKIT`. Standard build and loader search paths
(`LD_LIBRARY_PATH`, `DYLD_LIBRARY_PATH`, `DYLD_FRAMEWORK_PATH`, `LIBRARY_PATH`, and `PKG_CONFIG_PATH`) are also preserved:
their `_PATH` suffix otherwise matches `_PAT`. Other matching variables, including `BARS_*` credentials, are removed.
Use synthetic dictionaries or set synthetic sentinels inside fixtures; never depend on inherited real credentials.
For direct `swift test`, source the script in a Bash subshell first. This does not authorize live account tests.

`make test`, `make test-fast`, and `make test-skip-build` also give test discovery and execution a temporary
`HOME` and `CFFIXED_USER_HOME`, removed when the invocation ends. This keeps incidental default cost-store
access out of the developer's cache. Direct `swift test` callers must provide their own isolated home.

`@ProcessEnvironment` provides count-only descriptions and reflection for stored process-environment dictionaries
throughout the app, CLI, provider contexts, and session scanners. Use it on every stored environment, including
captured configuration structs and optional dictionaries. Optional storage preserves `nil` versus an empty map;
equality still compares the original contents. Keep formerly immutable properties `private(set)`.
Explicit dictionary access still returns the original values for provider/subprocess use; never log that dictionary.
Harness scrubbing remains essential and does not replace a review of debug output before sharing it.

`ProcessEnvironmentStorageTests` scans shipped Swift in `Sources/` and `WidgetExtension/` for environment-named
dictionary declarations (including optional, multiline, and `Dictionary<String, String>` spellings). This lexical
tripwire checks locals too; its exact-source allowlist documents only transient dictionaries and rejects stale or
duplicate exceptions. Computed getters and function parameters are not storage. Inferred types, aliases, differently
named dictionaries, and explicit dictionary logging still require code review; this is not a Swift dataflow analyzer.

Lint tools are installed at repository-pinned versions by `Scripts/install_lint_tools.sh`, with archive checksums
verified before installation. TypeScript 7 installs its native package for the running Node platform and architecture
(including Rosetta). Plugin typechecking uses only its declared libraries and source declarations, so unrelated
ancestor `node_modules/@types` packages do not affect the result. SwiftFormat targets the package's Swift 6.2 floor.

`make check` and `make lint` use the portable `lint-linux` checks on Linux. On macOS, they run the full
`lint` checks, including app localization, the AppleScript installer regression, and SwiftFormat.

```bash
make test
```

For focused iteration, use native SwiftPM filters with the same file/Keychain isolation and process containment:

```bash
make test-fast FILTER='AdaptiveRefreshPolicyTests'
make test-skip-build FILTER='(?<suite>AdaptiveRefreshPolicyTests)'
./Scripts/test_fast.sh --filter FirstSuite --filter SecondSuite --configuration debug
```

`FILTER` is passed literally, including Make/shell syntax and apostrophes. The script forwards all arguments to
`swift test`; SwiftPM owns regex syntax and repeated-filter selection. Runs are serial by default and have a
30-minute build-and-test deadline, configurable with `BARS_TEST_NATIVE_TIMEOUT`. An explicit `--skip-build` uses
existing binaries. No framework search-path override is added.

`make test` remains the complete sharded path. Measured expensive suites run in their own groups, retaining all
selections and their deadlines while avoiding whole-batch retries. Apple-Silicon macOS CI includes the CLI entry suite;
the former Intel-runner exclusion is retired.

Ordinary settings fixtures use an instance-owned Keychain access policy, including direct `SettingsStore`
initializers. Tests that deliberately exercise the process-wide gate must explicitly inject `.live` and restore it.

Claude OAuth gate tests use `ClaudeOAuthDefaultsFixtures()` so each test case owns an in-memory preferences store.
Keep reset, expiry, and persisted-key assertions inside that scope; nested tasks inherit it, detached tasks do not.
The gates retain their normal production defaults domain. Continue serializing shared gate state and same-host
full-suite runs: isolating these preferences does not isolate every test dependency.

`make test` and `make check` require a `python3` that provides `os.waitid` with `WNOWAIT`. Some macOS Python
builds, including Apple's `/usr/bin/python3`, do not provide it. The test runner then stops before its initial
Swift discovery/build and names the interpreter path, its version, and the missing attributes. Earlier
`make check` checks may already have run. For an installed Homebrew Python, select its generic commands with:

```bash
PATH="$(brew --prefix python@3.14)/libexec/bin:$PATH" make check
PATH="$(brew --prefix python@3.14)/libexec/bin:$PATH" make test
```

`Scripts/test.sh --list-only` does not need process containment, but still invokes `swift test list`, which may build.

The test target locates frameworks in the products directory beside its XCTest bundle. This supports native focused
tests on fresh SwiftPM builds. The sharded runner retains its guarded runtime recovery for differing toolchain
layouts, and `make test` remains the full validation path.

Suite commands retain the default 180-second deadline, including SwiftPM startup and discovery.
The runner reports elapsed time and owned PIDs every 30 seconds even when test output is buffered.
It tracks process birth identities and descendants, including helpers that create separate process
groups or sessions, and drains them before retrying. Separate sessions are allowed: the shell runner
uses them to protect controlling-terminal ownership. The direct command remains unreaped until cleanup
finishes (`waitid` with `WNOWAIT`), preventing reuse of its PID/session. Observed descendant session
leaders can establish ownership of orphaned session members only while a matching live or unreaped
birth identity still anchors that session. Known descendants retain their identities after reparenting;
empty completed sessions retire. If an observed session loses its anchor while unaccounted live members
remain, observation may retain that session as pending only while the direct command is still wait-owned
and running. A nested runner can then finish draining its own child: its unreaped wait handle is not
signal authority for the outer observer, and macOS may hide the exited leader's metadata. Pending members
remain birth-checked even if they change sessions. Uncertainty also follows observed descendants and peers
of a live matching pending session leader, with compatible birth ordering; those identities remain pending
after reparenting or session migration. Unreadable pending metadata fails closed; confirmed exits or replaced
pending births retire without claiming replacements. Pending status grants no ownership or signal authority.
Command exit and every cleanup path require session continuity and fail if uncertainty remains; a detected
replacement session-leader birth still fails immediately, even during observation.
No observation or cleanup deadline is extended. Unavailable metadata for a
known identity also fails cleanup; an unreadable unrelated peer does not abort enumeration.
For the direct child, confirmed metadata absence (ESRCH/ENOENT) can precede a waitable exit on
Darwin. Its unreaped wait handle retains ownership while ordinary polling continues within the
original command deadline. Pending wait status is not completion; permission and I/O errors still
fail. Direct-child cleanup signals require retained wait ownership, even if no birth metadata was
captured. Other PIDs continue to require verified birth identities.

Cleanup sends TERM to verified individual identities, escalates after three seconds, and requires the
owned set to drain within five seconds. Error paths make a final bounded attempt against readable known
identities and reap the direct child, then propagate failure instead of starting another suite/retry.
Initialization failures similarly TERM/KILL/reap the still-owned direct child. Linux treats a zombie
leader with other threads as running. Other PIDs require birth checks before signals, with pidfds used
on Linux when available. macOS descendant signals use `proc_signal_with_audittoken`: a combined native
BSD/unique-identity read must match the tracked birth, then the kernel binds the signal to that PID's
generation while checking the caller's normal signal permissions. A stale generation (including an
exec race) is not signaled; later cleanup attempts can refresh it after matching birth again. Missing
native signal support, permission failures, and I/O errors fail cleanup without a numeric-PID fallback.

This is a bounded metadata polling tracker, not a daemon sandbox. A new session whose leader and attached
ancestry both disappear entirely between observations cannot be discovered reliably. Snapshot enumeration
is not atomic, and unreadable, never-observed descendants cannot be attributed. The initial `swift test list`
discovery/build path is unchanged; the 180-second bound applies to each suite/group command, including its
startup. `Scripts/test_swift_test_sharding.sh` includes synthetic containment tests; they do not launch
Swift, the app, or provider probes. Its native pthread regression runs only on Linux and uses the system C
compiler; macOS runs the corresponding metadata unit tests and reports the native case as skipped.
macOS also runs native audit-token fixtures: deliberately wrong generations leave owned children alive,
matching identities TERM/KILL and reap them, and unrelated sentinels survive. These fixtures use stop
files and self-expiry, with final cleanup restricted to their unreaped direct children.

Process-cleanup fixtures keep ancestry alive until the real ownership refresh observes matching ready
child identities (and the session-tree grandchild), then acknowledges a private fixture gate before drain.
The direct `waitid` fixture uses the same handshake without reaping its root. Success/failure fixtures keep
their five-second command budget; timeout fixtures keep two seconds. A virtual-clock readiness test proves
one-second startup adds no fixed ancestry sleep. Gate waits are bounded and stop-file aware; helper
self-expiry remains 20 seconds.
The nested failure regression gates the inner drain and controls outer snapshots: the outer observer
sees a live session leader first, then its previously unseen orphan with the exited leader hidden.
Only the inner wait owner drains that orphan; the outer runner must complete without claiming it.
Contract tests also require unresolved sessions to fail at cleanup and reject reused leader births.

Cost performance and fair-scheduling corpora use exclusive initial fixture creation: the scanner only
reads after setup has closed each file. This avoids per-file atomic publication and durability work
without changing corpus contents or scan budgets. The shared atomic fixture writer remains available
for replacement and publication tests.

Menu fixtures use `enableTestProviders` to arrange their initial provider selection without repeatedly persisting
already-correct config entries. The real setter still handles changed flags and selected-provider cleanup. Keep
provider-toggle actions under test on the production setter; the fixture helper is for setup before observing changes.

### Cost scanner CPU regressions

Cost marker searches compare exact UTF-8 bytes with bounded libc `memchr` and `memcmp` calls.
Both buffers remain borrowed during the search, and candidate starts stop at the last position
where the complete needle fits. Empty needles retain Foundation's `Data.range(of:)` behavior.
`CostUsageAsciiSearchTests` compares results with Foundation, including nonzero-index data views,
binary bytes, Unicode, repeated prefixes, and matches at the buffer boundary.
JSON decoding, parser classification, and resumable scan state keep their existing paths.
The parser-hash change retains `3f88178bf03ad704` as a tested compatible native-store predecessor.

`CostUsageJsonl` finds complete physical LF spans with bounded libc `memchr` on Darwin, Glibc, and
Musl, using the same span algorithm with scalar LF search elsewhere. Borrowed pointers stay inside
the current `withUnsafeBytes` call; search counts and distances fit the existing 256 KiB read chunk.
Complete spans keep the original prefix-copy and flush path. Unfinished chunk suffixes still run the
original scalar JSON tail updater, preserving exact resumable state and EOF validation. CR bytes,
empty-line offsets, independent prefix/max limits, budgets, and cancellation/stop ordering are unchanged.

Persisted Codable checkpoints are a compatibility boundary, including unusual decoded counters.
Skipping tail updates requires a nonnegative line count, safe container-depth arithmetic for the span,
and nonnegative literal indices. Otherwise the same scalar updater runs before the existing flush;
this preserves its checked operations and state when the flush does not reset a negative line count.
Do not replace this guard with checkpoint normalization or a new corrupt-cache recovery policy.

### Adaptive refresh fixtures

Heuristics and timer tests seed disabled providers through `testSettingsStore(config:)`, which saves the
file-backed config before settings initialization. They do not replay a synchronous config write for each
provider toggle during setup. The seed preserves provider defaults. Reset-boundary tests then enable only the
stubbed provider under test. Timer intervals, polling deadlines, and production persistence behavior remain unchanged.

### Claude session fixtures

Profile/reuse and overlapping-capture tests wait for the fixture's expected `Account:` response with idle
completion disabled; PTY command echo alone is not functional completion. The profile/reuse test keeps both
immediate responses and a controlled 0.5-second response delay, beyond the former 0.1-second idle window.
Capture budgets remain two seconds for profile/reuse and five seconds for overlap. Account, environment,
launch-count, isolation, and stale-artifact assertions remain independent of the completion condition.

### CI Aggregate Contract

`make check` and portable CI lint run `node Scripts/check-package-resolved.mjs` and its synthetic regression tests
(`node --test Scripts/test_package_resolved.mjs`). This offline, read-only check compares every package identity,
revision, and version in the root and widget workspace `Package.resolved` files, including missing or extra pins.
Pin order and workspace-specific `originHash` values do not affect the comparison. After changing dependencies,
resolve the widget workspace from the repository root and commit both resolved files together:

```bash
xcodebuild -resolvePackageDependencies -project WidgetExtension/BarsWidgetExtension.xcodeproj
```

The check names each drifted package and prints this repair command before packaging can fail with an out-of-date
resolved file when automatic resolution is disabled.

`Scripts/test_ci_path_gate.sh` checks the shared path decisions used by `.github/workflows/ci.yml`: docs-only changes
skip builds, while source, test, widget, and workflow paths always require them, including Markdown resources and
fixtures.

### Format Code

```bash
swiftformat Sources Tests
swiftlint --strict
```

## Distribution

### Local Development Build
```bash
./Scripts/package_app.sh
# Creates: bars.app (ad-hoc signed)
```

Builds are always ad-hoc signed; there is no Developer ID, notarization, or release pipeline. The sandboxed launch
smoke check is retained; `BARS_SKIP_LAUNCH_SMOKE=1` explicitly reports that it skipped validation.

## Troubleshooting

### App Won't Launch
```bash
# Check crash logs
ls -lt ~/Library/Logs/DiagnosticReports/bars* | head -5

# Check Console.app for errors
# Filter: process:bars
```

### Keychain Prompts Keep Appearing
Confirm the prompt's requested item and requesting binary, then check for another running or installed bars copy.
Do not validate a fix by querying the real Keychain from routine tests. See [Keychain prompts](keychain-prompts.md).

### Cookies Not Refreshing
1. Check the browser is in the shared default browser order
2. Verify you're logged into claude.ai in that browser
3. Check Preferences → Providers → Claude → Cookie source is "Automatic"
4. Enable debug logging and check Console.app

### Main-Thread Hangs

Debug builds start the hang watchdog automatically. To diagnose a release build,
enable it explicitly and restart bars:

```bash
defaults write com.sirrayi.bars debugMainThreadHangWatchdog -bool true
```

Hangs are written to the app log. Hangs over two seconds also request a process
sample under `~/Library/Logs/bars/`. Disable the release opt-in with:

```bash
defaults delete com.sirrayi.bars debugMainThreadHangWatchdog
```

## Architecture Notes

### Menu Bar App Pattern
- No dock icon (LSUIElement = true)
- Status item only (NSStatusBar)
- SwiftUI for preferences, AppKit for menu
- Hidden 1×1 window keeps SwiftUI lifecycle alive

### Cookie Management
- Automatic browser import via SweetCookieKit
- Keychain cache for some imported browser cookies and OAuth/device-flow credentials
- The resolved config file for provider settings, manual cookies, and stored API keys: new installs use
  `~/.config/bars/config.json`, while existing `~/.bars/config.json` installs retain their legacy path
- Manual override for debugging
- Browser-cookie import when cached sessions need refresh

### Usage Polling
- Background timer (configurable frequency)
- Parallel provider fetches
- First failure can be suppressed when prior data exists
- WidgetKit snapshot for macOS widgets

### macOS direct test groups

`make test` remains serial by default. Invoke
`./Scripts/test.sh --direct-workers 4` to request up to eight isolated group workers locally.
SwiftPM still builds and discovers the complete inventory. Before launch, the adapter enumerates
both XCTest and Swift Testing using the selected Xcode toolchain helpers and requires an exact
inventory match, including duplicate detection. An inventory mismatch fails the run before any
group executes. Local runs with missing helpers, unsupported toolchains, or Linux retain the serial
SwiftPM path with a diagnostic. On CI, requesting direct workers requires a verified direct runtime:
capability failures also fail the job instead of falling back to serial execution.

Hosted macOS CI runs the complete inventory with two direct workers on one `xcode-27` (Xcode 27)
runner, retaining the 75-minute test step and 90-minute job limits. All groups are required:
discovery, admission, helper crashes, unrecovered timeouts and test failures fail the job. Group size remains
eight with a 120-second suite timeout and no retries for ordinary test failures. Timed-out groups retain
the existing isolated-selection retry policy; each retry has its own deadline. Three independent
hosted complete-inventory runs validated this mode before enabling it.
Both serial and direct modes print ordered selection groups and timing summaries.

Each macOS job restores a compiled SwiftPM cache bound to its toolchain, SDK, architecture,
package state and build scripts/options. The helper verifies tracked input contents and permissions
before restoring unchanged file timestamps. Changed contents invalidate preserved or backdated
timestamps; added/deleted package paths or changed package symlink targets require clean products.
Missing, invalid or unverifiable metadata also cleans products before rebuilding. Symlink payloads
are checked without following them; reuse requires each package link to name a regular tracked file
in both snapshots, whose contents are verified separately. External, untracked, chained and directory
targets, including noncanonical paths that could conceal a symlink ancestor, require clean products
without reading or modifying the target. Only successful main jobs with a clean tracked tree
save new snapshots, and cleanup keeps one snapshot per active lane and deletes retired lanes. The first main run seeds the cache;
a cache miss or a changed input graph still requires a cold build.

The adapter includes both public and private platform framework search paths and disables Swift
Testing during XCTest discovery, matching SwiftPM's launcher. Probe failures print the helper,
exit status or signal, and redacted stdout/stderr. On CI, signal failures also wait up to five
seconds for fresh helper crash reports in the original and temporary homes. The workflow collects
fresh test crash reports again after failures in the required full test job. Credential
values and local home identities are redacted; unrelated process reports are excluded.

Each group has a fresh process and temporary `HOME` and `CFFIXED_USER_HOME`, with the existing credential
and session-file isolation, Keychain suppression, timeout, retry, and descendant cleanup.
Async process fixtures should use `ProcessExitRelease.afterExit` after signaling a Foundation child,
instead of blocking a cooperative executor in `waitUntilExit()`. PTY setup tests should keep the child
alive until its output is observed; Darwin can discard unread output when the last slave descriptor closes.
The TTY runner retains its slave descriptor until it has harvested output after child exit, then closes it
before checking EOF. The fast-exit regression waits for child exit before the first read, without a timed delay.
Compare working directories after resolving symlinks.

Detached SIGTERM-ignoring fixtures use `KiroProcessTestSupport` to watch the test process with kqueue
`NOTE_EXIT`, with a 120-second backstop. Watch the test process rather than a short-lived fixture parent;
heartbeat loops also retain an absolute deadline so they cannot wait forever while the owner remains alive.
Test output is buffered per group. A direct runtime failure after execution begins fails the run;
it does not silently rerun the suite through a different runtime. This opt-in adapter depends on
SwiftPM's toolchain helper contract and needs compatibility validation when updating Xcode.

`--swift-command /path/to/swift-wrapper` works when the wrapper forwards `-print-target-info`
unchanged to the selected Xcode Swift compiler and supports `build --show-bin-path`. The runner
queries the wrapper's products directory; a different compiler/target or command prefix arguments
are rejected (local serial fallback, CI failure). For a host requiring the native build backend,
use the same wrapper for serial and direct comparisons:

```bash
#!/bin/bash
set -euo pipefail
case "${1:-}" in
  test|build)
    subcommand="$1"
    shift
    exec /usr/bin/xcrun swift "$subcommand" --build-system native --jobs 4 -Xswiftc -gnone "$@"
    ;;
  *) exec /usr/bin/xcrun swift "$@" ;;
esac
```

Save it as an executable file, then invoke
`./Scripts/test.sh --swift-command /path/to/swift-wrapper --direct-workers 4`.
Wrappers may add build options; test-selection or runtime-environment changes inside a wrapper
cannot be reproduced by direct launch and are unsupported. Live/opt-in tests remain disabled by
their existing test conditions; this flag does not enable them.
