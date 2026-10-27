---
summary: "Opt-in startup traces for missing Tahoe menu bar items."
read_when:
  - Investigating missing status items or Control Center hosting
  - Preparing a diagnostic build for issue 3377
---

# Status-item startup diagnostics

Launch with `BARS_STATUS_ITEM_DIAGNOSTICS=1` to write newline-delimited JSON to stdout, capped at 128 records per process. Logging defaults off. Tracing adds no UI, permission requests, or recovery behavior, reads no credentials, and captures no pixels. Normal startup still includes configured provider refreshes.

Stages: `will-finish-launching`, `did-finish-launching`, `created` (zero width), `named`, `sized`, `rendered`, `startup-check` (about two seconds), and `settled` (about 15 seconds). Later creation/recovery can add records within the cap. Timestamps use system uptime.

Records include autosave identity, visibility, length, main-thread/running state, activation policy (`0` regular, `1` accessory, `2` prohibited), AppKit button/window numbers and frames, and screen frames. Rendered/check/settled records add expected visibility and the `VisibleCC` default. Recognized empty SwiftUI Settings windows include number, geometry, and visibility, without titles; size alone does not identify a window.

`controlCenter` contains the layer-25 window count, sorted window numbers, unnamed count, and autosave-name candidates (number, Quartz bounds, onscreen state). It excludes other apps' window titles and provider/account content. `windowQuerySucceeded=false` means the query failed, not zero windows.

A named match is only a **candidate**: names can collide or be redacted, and AppKit/Quartz coordinates differ. Do not infer hosting/rendered pixels from a match or trigger recovery from an empty match. Compare the full Control Center window-number set before creation and after settling, plus AppKit and candidate Quartz geometry. AppKit/WindowServer queries can perturb timing-sensitive failures; report if tracing changes the symptom.

## Reporter capture

Use a maintainer-signed diagnostic app. For #3377, preserve the production `com.sirrayi.bars` identity and Developer ID; an ordinary debug package has a different identity and serves only as a control. Do not reset preferences or move group containers.

Quit the existing bars instance once before starting the diagnostic copy, so two instances do not compete
for the same autosave name. Then run the supplied app executable directly (adjust the app path):

```sh
umask 077
BARS_STATUS_ITEM_DIAGNOSTICS=1 \
  /path/to/bars.app/Contents/MacOS/bars > "$HOME/Desktop/bars-status-items.jsonl"
```

Wait at least 20 seconds. Record whether the icon appeared, whether Bartender was running, and whether the
allow-list toggle remained on. Quit the diagnostic app normally or end this foreground run with Control-C,
then return to the installed app. No persistent environment or settings change is needed.
Inspect the JSON file before sharing it; send it with the build commit and the observed symptom. Do not attach
unrelated application logs. Repeat once with Bartender already quit only if the first capture is inconclusive.

## Diagnostic build

Build a debug bundle from the diagnostic commit with `./Scripts/package_app.sh debug`. Its
`com.sirrayi.bars.debug` identity is separate from the release identity, so a debug trace cannot by itself
establish a fix for the release build.
