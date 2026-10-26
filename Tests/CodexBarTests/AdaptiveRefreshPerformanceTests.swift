import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

private final class DirectoryEntryVisitCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() {
        self.lock.withLock { self.value += 1 }
    }

    var count: Int {
        self.lock.withLock { self.value }
    }
}

private actor AdaptiveLocalScanSpy {
    private(set) var callCount = 0

    func scan(includeFileOnlySessions _: Bool) -> [AgentSession] {
        self.callCount += 1
        return []
    }
}

@MainActor
struct AdaptiveRefreshPerformanceTests {
    @Test
    func `plain adaptive and missing consent perform zero local scans`() async {
        let settings = testSettingsStore(suiteName: "AdaptiveRefreshPerformanceTests-zero-scan")
        settings.agentSessionsEnabled = false
        settings.adaptiveActivityScanConsent = .allowed
        settings.refreshFrequency = .adaptive
        let spy = AdaptiveLocalScanSpy()
        let store = AgentSessionsStore(
            settings: settings,
            localScan: { includeFileOnlySessions in
                await spy.scan(includeFileOnlySessions: includeFileOnlySessions)
            })
        store.start()
        defer { store.stop() }

        store.settingsDidChange(remoteConfigurationChanged: false)
        await store.refreshLocal()
        #expect(!store.schedulerState.hasLocalPeriodicTask)
        #expect(!store.schedulerState.hasLocalImmediateTask)
        #expect(await spy.callCount == 0)

        settings.refreshFrequency = .adaptiveAgentAware
        settings.adaptiveActivityScanConsent = .undecided
        store.settingsDidChange(remoteConfigurationChanged: false)
        await store.refreshLocal()
        #expect(!store.schedulerState.hasLocalPeriodicTask)
        #expect(!store.schedulerState.hasLocalImmediateTask)
        #expect(await spy.callCount == 0)

        settings.adaptiveActivityScanConsent = .declined
        store.settingsDidChange(remoteConfigurationChanged: false)
        await store.refreshLocal()
        #expect(!store.schedulerState.hasLocalPeriodicTask)
        #expect(!store.schedulerState.hasLocalImmediateTask)
        #expect(await spy.callCount == 0)
    }
}
