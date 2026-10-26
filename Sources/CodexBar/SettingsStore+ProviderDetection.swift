import AppKit
import CodexBarCore
import Foundation

enum ProviderDetectionPolicy {
    struct Signals {
        let codexCLIInstalled: Bool
        let claudeCLIInstalled: Bool
        let claudeDesktopInstalled: Bool
    }

    static func enabledProviders(signals: Signals) -> Set<UsageProvider> {
        // Provider-specific by design: first-run detection probes these four concrete CLI/app credential sources.
        var enabled: Set<UsageProvider> = []
        if signals.codexCLIInstalled {
            enabled.insert(.codex)
        }
        if signals.claudeCLIInstalled || signals.claudeDesktopInstalled {
            enabled.insert(.claude)
        }

        // Keep the historical Codex default when no usable provider source is found.
        if enabled.isEmpty {
            enabled.insert(.codex)
        }
        return enabled
    }
}

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
        let codexCLIInstalled = BinaryLocator.resolveCodexBinary() != nil
        let claudeCLIInstalled = BinaryLocator.resolveClaudeBinary() != nil
        let claudeDesktopInstalled = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.anthropic.claudefordesktop") != nil
        let logger = CodexBarLog.logger(LogCategories.providerDetection)

        let enabledProviders = ProviderDetectionPolicy.enabledProviders(signals: .init(
            codexCLIInstalled: codexCLIInstalled,
            claudeCLIInstalled: claudeCLIInstalled,
            claudeDesktopInstalled: claudeDesktopInstalled))

        logger.info(
            "Provider detection results",
            metadata: [
                "codexCLIInstalled": codexCLIInstalled ? "1" : "0",
                "claudeCLIInstalled": claudeCLIInstalled ? "1" : "0",
                "claudeDesktopInstalled": claudeDesktopInstalled ? "1" : "0",
            ])
        logger.info(
            "Provider detection enablement",
            metadata: [
                "codex": enabledProviders.contains(.codex) ? "1" : "0",
                "claude": enabledProviders.contains(.claude) ? "1" : "0",
            ])

        self.updateProviderConfig(provider: .codex) { entry in
            entry.enabled = enabledProviders.contains(.codex)
        }
        self.updateProviderConfig(provider: .claude) { entry in
            entry.enabled = enabledProviders.contains(.claude)
        }
        self.providerDetectionCompleted = true
        logger.info("Provider detection completed")
    }
}
