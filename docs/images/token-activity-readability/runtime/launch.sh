#!/usr/bin/env bash
# Build an isolated full-app proof with synthetic history; retain the checkout and private logs.
set -euo pipefail
REPO_ROOT="$(git rev-parse --show-toplevel)"
PROOF_SOURCE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ActivityDashboardRuntimeProof.swift"
PROOF_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/bars-activity-proof.XXXXXX")"
PROOF_CHECKOUT="${PROOF_ROOT}/checkout"
git -C "${REPO_ROOT}" worktree add --detach "${PROOF_CHECKOUT}" HEAD
cp "${PROOF_SOURCE}" "${PROOF_CHECKOUT}/Sources/Bars/ActivityDashboardRuntimeProof.swift"
python3 - "${PROOF_CHECKOUT}" <<'PYTHON'
from pathlib import Path
import sys
root = Path(sys.argv[1])
entry = root / "Sources/Bars/BarsApp.swift"
text = entry.read_text()
marker = "        if MenuBarLayoutNativeProof.runIfRequested() {"
assert text.count(marker) == 1
entry.write_text(text.replace(marker, "        if ActivityDashboardRuntimeProof.runIfRequested() {\n            return\n        }\n" + marker))
stores = (root / "Tests/BarsTests/TestStores.swift").read_text().split("#if os(macOS)\n@MainActor\nfunc testStatusBar", 1)[0]
stores = stores.replace("@testable import bars\n", "")
setter = "    override func set(_ value: Any?, forKey defaultName: String) {\n        self.lock.withLock { self.values[defaultName] = value }\n    }"
notifying_setter = "    override func set(_ value: Any?, forKey defaultName: String) {\n        self.willChangeValue(forKey: defaultName)\n        self.lock.withLock { self.values[defaultName] = value }\n        self.didChangeValue(forKey: defaultName)\n    }"
assert stores.count(setter) == 1
stores = stores.replace(setter, notifying_setter)
zai = (root / "Tests/BarsTests/ZaiTokenStoreTestSupport.swift").read_text().replace("@testable import bars\n", "")
(root / "Sources/Bars/ActivityRuntimeProofTestStores.swift").write_text("#if DEBUG\n" + stores.rstrip() + "\n\n" + zai.lstrip() + "\n#endif\n")
PYTHON
cd "${PROOF_CHECKOUT}"
source Scripts/test_environment.sh
BARS_SIGNING=adhoc Scripts/package_app.sh debug > "${PROOF_ROOT}/package-private.log" 2>&1
mv bars.app BarsActivityProof.app
python3 - "${PROOF_ROOT}" <<'PYTHON'
from pathlib import Path
import plistlib, sys
root = Path(sys.argv[1])
p = root / "checkout/BarsActivityProof.app/Contents/Info.plist"
info = plistlib.loads(p.read_bytes())
info["CFBundleIdentifier"] = "org.codex.proof.activity." + root.name.rsplit(".", 1)[-1].lower()
info["CFBundleName"] = info["CFBundleDisplayName"] = "bars Activity Proof"
p.write_bytes(plistlib.dumps(info))
PYTHON
codesign --force --deep --sign - BarsActivityProof.app
codesign --verify --deep --strict BarsActivityProof.app
export SWIFT_TESTING_ENABLED=1
export BARS_ACTIVITY_RUNTIME_PROOF_DIR="${PROOF_ROOT}/raw"
printf 'Proof checkout and private originals retained at: %s\n' "${PROOF_ROOT}"
./BarsActivityProof.app/Contents/MacOS/bars --activity-dashboard-proof > "${PROOF_ROOT}/runtime-private.log" 2>&1
