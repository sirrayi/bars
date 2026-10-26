import Foundation

/// Deterministic launch-time probe for the packaged-app resource smoke check
/// (`Scripts/verify_packaged_app_launch.sh`, #2738).
///
/// 0.48.0 shipped a `Bundle.module`-based resource load that trapped at launch
/// on every machine without the build checkout. The loads are lazy, so a plain
/// "launch and stay alive" check only catches the regression when some provider
/// happens to hit the code path within the observation window. This probe makes
/// the check deterministic: when `CODEXBAR_RESOURCE_SMOKE=1` is set, the app
/// forces the resource loads before any UI or AppKit setup and exits, so the
/// packaging pipeline can run it headless with the checkout made unreachable.
/// A regression back to a compile-time-path accessor either fatal-traps
/// (caught by the caller's stderr signature) or reports a failure here.
public enum CodexBarCoreResourceSmoke {
    public static let environmentFlag = "CODEXBAR_RESOURCE_SMOKE"
    public static let successMarker = "CODEXBAR_RESOURCE_SMOKE_OK"

    public static func isRequested(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        environment[self.environmentFlag] == "1"
    }

    /// Returns the list of failures; empty means every probed resource load succeeded.
    public static func failures() -> [String] {
        var failures: [String] = []
        // Touching the resolver (and, through it, `Bundle.module` outside app
        // contexts) is the load that trapped in 0.48.0.
        guard let bundle = CodexBarCoreResources.bundle else {
            return [CodexBarCoreResources.missingBundleMessage]
        }

        return failures
    }

    /// Runs the probe and reports; returns the intended process exit code.
    public static func run() -> Int32 {
        let failures = self.failures()
        guard failures.isEmpty else {
            for failure in failures {
                FileHandle.standardError.write(Data("RESOURCE SMOKE FAILURE: \(failure)\n".utf8))
            }
            return 1
        }
        print(self.successMarker)
        return 0
    }
}
