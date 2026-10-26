import AppKit
import CodexBarCore
import Foundation

extension SettingsStore {
    func runInitialProviderDetectionIfNeeded(force: Bool = false) {
        guard force || !self.providerDetectionCompleted else { return }
        LoginShellPathCache.shared.captureOnce { [weak self] _ in
            Task { @MainActor in
                await self?.applyProviderDetection()
            }
        }
    }

    func applyProviderDetection() async {
        guard !self.providerDetectionCompleted else { return }
        // Provider-specific by design: detection reads each provider's installed app, CLI, or credential artifact.
        let claudeCLIInstalled = BinaryLocator.resolveClaudeBinary() != nil
        let claudeDesktopInstalled = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.anthropic.claudefordesktop") != nil
        let logger = CodexBarLog.logger(LogCategories.providerDetection)

        logger.info(
            "Provider detection results",
            metadata: [
                "claudeCLIInstalled": claudeCLIInstalled ? "1" : "0",
                "claudeDesktopInstalled": claudeDesktopInstalled ? "1" : "0",
            ])
        // Claude is the only first-run detected provider and stays the default when no source is found.
        self.updateProviderConfig(provider: .claude) { entry in
            entry.enabled = true
        }
        self.providerDetectionCompleted = true
        logger.info("Provider detection completed")
    }
}
