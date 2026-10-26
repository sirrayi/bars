import CodexBarCore
import Foundation

extension SettingsStore {
    func costSummaryShowsInline(for provider: UsageProvider) -> Bool {
        self.costUsageEnabled && self.costSummaryDisplayStyle.showsInlineSummary
    }

    func costSummaryShowsSubmenu(for provider: UsageProvider) -> Bool {
        self.isCostUsageEffectivelyEnabled(for: provider) &&
            self.costSummaryDisplayStyle.showsCostSubmenu
    }

    func applyTokenCostDefaultIfNeeded() {
        // Tests cover detection directly; skip filesystem-driven auto-enablement to keep startup deterministic.
        guard !Self.isRunningTests else { return }
        // Settings are persisted in UserDefaults.standard.
        guard UserDefaults.standard.object(forKey: "tokenCostUsageEnabled") == nil else { return }

        Task { @MainActor [weak self] in
            guard let self else { return }
            let environment = ProcessInfo.processInfo.environment
            let hasSources = await Task.detached(priority: .utility) {
                Self.hasAnyTokenCostUsageSources(env: environment)
            }.value
            guard hasSources else { return }
            guard UserDefaults.standard.object(forKey: "tokenCostUsageEnabled") == nil else { return }
            self.costUsageEnabled = true
        }
    }

    nonisolated static func hasAnyTokenCostUsageSources(
        env: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        homeDirectory: URL? = nil,
        workingDirectory: URL? = nil) -> Bool
    {
        // Provider-specific by design: Claude's local stores can auto-enable token cost.
        let home = homeDirectory ?? fileManager.homeDirectoryForCurrentUser

        func hasAnyJsonl(in root: URL) -> Bool {
            guard fileManager.fileExists(atPath: root.path) else { return false }
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants])
            else { return false }

            for case let url as URL in enumerator where url.pathExtension.lowercased() == "jsonl" {
                return true
            }
            return false
        }

        let claudeRoots = ClaudeConfigPaths.costProjectsRoots(
            environment: env,
            homeDirectory: home,
            fileManager: fileManager,
            workingDirectory: workingDirectory)

        return claudeRoots.contains(where: hasAnyJsonl(in:))
    }
}
