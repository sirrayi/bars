import AppKit
import CodexBarCore
import QuartzCore

extension StatusItemController {
    private static let defaultDeferredMenuInteractionRefreshDelay: Duration = .milliseconds(250)
    private static let slowMenuOperationThreshold: TimeInterval = 0.15
    private static let slowChartRenderThreshold: TimeInterval = 0.050

    #if DEBUG
    private static var deferredMenuInteractionRefreshDelayForTesting: Duration = .milliseconds(250)

    static func setDeferredMenuInteractionRefreshDelayForTesting(_ delay: Duration) {
        self.deferredMenuInteractionRefreshDelayForTesting = delay
    }

    static func resetDeferredMenuInteractionRefreshDelayForTesting() {
        self.deferredMenuInteractionRefreshDelayForTesting = self.defaultDeferredMenuInteractionRefreshDelay
    }
    #endif

    private static var deferredMenuInteractionRefreshDelay: Duration {
        #if DEBUG
        deferredMenuInteractionRefreshDelayForTesting
        #else
        defaultDeferredMenuInteractionRefreshDelay
        #endif
    }

    struct MenuOperationTrace {
        let operation: String
        let startedAt: CFTimeInterval
    }

    /// Pairs the slow-operation timing log with a watchdog breadcrumb so a hang during
    /// the operation is attributed to it even when the operation never finishes logging.
    func beginMenuOperationTrace(
        _ operation: String,
        breadcrumb: @autoclosure () -> String) -> MenuOperationTrace
    {
        MainThreadActivityBreadcrumb.push(breadcrumb())
        return MenuOperationTrace(operation: operation, startedAt: CACurrentMediaTime())
    }

    func endMenuOperationTrace(_ trace: MenuOperationTrace, menu: NSMenu, provider: UsageProvider?) {
        MainThreadActivityBreadcrumb.pop()
        self.logMenuOperationDurationIfSlow(
            trace.operation,
            startedAt: trace.startedAt,
            menu: menu,
            provider: provider)
    }

    func logMenuOperationDurationIfSlow(
        _ operation: String,
        startedAt: CFTimeInterval,
        menu: NSMenu,
        provider: UsageProvider?)
    {
        let elapsed = CACurrentMediaTime() - startedAt
        guard elapsed >= Self.slowMenuOperationThreshold else { return }
        self.menuLogger.warning(
            "slow menu operation",
            metadata: [
                "operation": operation,
                "durationMs": String(format: "%.1f", elapsed * 1000),
                "items": "\(menu.items.count)",
                "provider": provider?.rawValue ?? "nil",
                "openMenus": "\(self.openMenus.count)",
                "storeRefreshing": self.store.isRefreshing ? "1" : "0",
            ])
    }

    func logChartRenderDurationIfSlow(_ label: String, startedAt: CFTimeInterval) {
        let elapsed = CACurrentMediaTime() - startedAt
        guard elapsed >= Self.slowChartRenderThreshold else { return }
        self.menuLogger.warning(
            "slow chart render",
            metadata: [
                "section": label,
                "durationMs": String(format: "%.1f", elapsed * 1000),
            ])
    }

    func deferMenuInteractionRefreshIfNeeded(providers: [UsageProvider]) {
        guard !self.store.isRefreshing else { return }
        self.deferredMenuInteractionRefreshProviders.formUnion(providers.map(\.instanceID))
    }

    func clearSatisfiedDeferredMenuInteractionRefreshes(for providers: [ProviderInstanceID]) {
        for instanceID in providers {
            guard let provider = instanceID.firstPartyProvider,
                  !self.store.needsUsageRefreshRetry(for: provider)
            else { continue }
            self.deferredMenuInteractionRefreshProviders.remove(instanceID)
        }
    }

    func cancelDeferredMenuInteractionRefreshTask() {
        self.deferredMenuInteractionRefreshTask?.cancel()
        self.deferredMenuInteractionRefreshTask = nil
    }

    func scheduleDeferredMenuInteractionRefreshIfNeeded(delay: Duration? = nil) {
        guard self.openMenus.isEmpty else { return }
        guard self.deferredMenuInteractionRefreshPending else { return }
        guard !self.hasPreparedForAppShutdown else { return }

        self.cancelDeferredMenuInteractionRefreshTask()
        let delay = delay ?? Self.deferredMenuInteractionRefreshDelay
        self.deferredMenuInteractionRefreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            guard self.openMenus.isEmpty else {
                self.deferredMenuInteractionRefreshTask = nil
                return
            }
            let pendingProviders = self.deferredMenuInteractionRefreshProviders
            let hasProviderRefreshInFlight = pendingProviders.contains {
                self.store.refreshingProviders.contains($0)
            }
            guard !self.store.isRefreshing,
                  !self.store.hasForcedRefreshEnrichmentInFlight,
                  !hasProviderRefreshInFlight
            else {
                self.deferredMenuInteractionRefreshTask = nil
                self.scheduleDeferredMenuInteractionRefreshIfNeeded(
                    delay: Self.defaultDeferredMenuInteractionRefreshDelay)
                return
            }
            self.clearSatisfiedDeferredMenuInteractionRefreshes(for: Array(pendingProviders))
            guard self.deferredMenuInteractionRefreshPending else {
                self.deferredMenuInteractionRefreshTask = nil
                return
            }
            guard !self.hasPreparedForAppShutdown else {
                self.deferredMenuInteractionRefreshTask = nil
                return
            }
            self.deferredMenuInteractionRefreshTask = nil
            self.deferredMenuInteractionRefreshProviders.removeAll()
            #if DEBUG
            self.onDeferredMenuInteractionRefreshForTesting?()
            #endif
            await self.performStoreRefresh(
                forceTokenUsage: false,
                refreshOpenMenusWhenComplete: false,
                interaction: .background)
        }
    }
}
