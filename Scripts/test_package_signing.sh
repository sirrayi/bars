#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
PACKAGE_SCRIPT="$ROOT/Scripts/package_app.sh"
FUNCTIONS_FILE=$(mktemp "${TMPDIR:-/tmp}/bars-package-signing-functions.XXXXXX")
trap 'rm -f "$FUNCTIONS_FILE"' EXIT

python3 - "$PACKAGE_SCRIPT" "$FUNCTIONS_FILE" <<'PY'
import sys
from pathlib import Path

script = Path(sys.argv[1]).read_text()
functions = []
for name in ('verify_no_quarantine_attribute', 'verify_packaged_app_integrity'):
    start = script.index(f'{name}() {{')
    end = script.index('\n}\n', start) + 3
    functions.append(script[start:end])
Path(sys.argv[2]).write_text('\n\n'.join(functions))
PY

source "$FUNCTIONS_FILE"

TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/bars-package-signing.XXXXXX")
trap 'rm -f "$FUNCTIONS_FILE"; rm -rf "$TEMP_DIR"' EXIT
APP="$TEMP_DIR/bars.app"
mkdir -p "$APP/Contents/MacOS"

xattr() {
  if [[ "${MOCK_QUARANTINE:-0}" == "1" ]]; then
    printf '0081;fake;Safari;https://example.invalid\n'
    return 0
  fi
  return 1
}

codesign() {
  return "${MOCK_CODESIGN_STATUS:-0}"
}

verify_packaged_app_integrity "$APP"

export MOCK_QUARANTINE=1
if verify_packaged_app_integrity "$APP" 2>/dev/null; then
  echo "Quarantined app unexpectedly passed integrity verification" >&2
  exit 1
fi
unset MOCK_QUARANTINE

export MOCK_CODESIGN_STATUS=1
if verify_packaged_app_integrity "$APP" 2>/dev/null; then
  echo "App with an invalid signature unexpectedly passed integrity verification" >&2
  exit 1
fi
unset MOCK_CODESIGN_STATUS

python3 - "$PACKAGE_SCRIPT" "$ROOT/Scripts/compile_and_run.sh" <<'PY'
import plistlib
import subprocess
import sys
import tempfile
from pathlib import Path

source = Path(sys.argv[1]).read_text()
# Builds are ad-hoc only: no identity lookup, notarization, or restricted entitlements.
assert 'CODESIGN_ARGS=(--force --sign -)' in source
for forbidden in ('find-identity', 'APP_IDENTITY', '--timestamp', 'provisionprofile', 'icloud'):
    assert forbidden not in source, forbidden
assert 'find-identity' not in Path(sys.argv[2]).read_text()

start = source.index('BUNDLE_ID="com.sirrayi.bars"')
end = source.index('BUILD_TIMESTAMP=', start)
generation = source[start:end]
cases = 0
for configuration, bundle_id in (('release', 'com.sirrayi.bars'), ('debug', 'com.sirrayi.bars.debug')):
    for allow_lldb in ('0', '1') if configuration == 'debug' else ('0',):
        with tempfile.TemporaryDirectory(prefix='bars-entitlements-test-') as directory:
            root = Path(directory)
            subprocess.run(
                ['bash', '-c', f'set -euo pipefail\n{generation}'],
                check=True,
                env={'PATH': '/usr/bin:/bin', 'ROOT': str(root), 'LOWER_CONF': configuration,
                     'ALLOW_LLDB': allow_lldb})
            group = f'BARSADHOC1.{bundle_id}'
            app = plistlib.loads((root / '.build/entitlements/bars.entitlements').read_bytes())
            widget = plistlib.loads((root / '.build/entitlements/BarsWidget.entitlements').read_bytes())
            assert app['com.apple.security.application-groups'] == [group], app
            assert widget['com.apple.security.application-groups'] == [group], widget
            assert widget['com.apple.security.app-sandbox'] is True
            assert app.get('com.apple.security.get-task-allow', False) == (allow_lldb == '1')
            assert not any('icloud' in key for key in app), app
            cases += 1
print(f'{cases} ad-hoc entitlement cases passed without signing or Keychain access.')
PY

echo "Package signing tests passed."
