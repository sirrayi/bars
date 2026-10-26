import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct ProviderStatusRefreshPublicationTests {
    @Test
    func `late scoped status cannot replace a newer background status`() async {
        let store = Self.makeStore()
        let gate = StatusPublicationGate()
        var requests = 0
        store._test_providerStatusFetchOverride = { _ in
            requests += 1
            if requests == 1 {
                await gate.suspend()
                return Self.status(.none, description: "Older operational status")
            }
            return Self.status(.major, description: "Current incident")
        }

        let scopedRefresh = Task {
            await ProviderInteractionContext.$current.withValue(.userInitiated) {
                await store.refreshProvider(.opencode)
                await store.refreshProviderStatus(.opencode)
            }
        }
        await gate.waitUntilStarted()
        #expect(!store.isRefreshing)
        let completed = await store.runRefresh(startupConnectivityRetryAttempt: nil)
        #expect(completed)
        #expect(requests == 2)
        #expect(store.statuses[.opencode]?.description == "Current incident")
        #expect(store.providerStatusHadIssue[.opencode] == true)

        await gate.resume()
        await scopedRefresh.value

        #expect(store.statuses[.opencode]?.description == "Current incident")
        #expect(store.providerStatusHadIssue[.opencode] == true)
        await store.tokenRefreshSequenceTask?.value
        store.memoryPressureReliefTask?.cancel()
        await store.memoryPressureReliefTask?.value
    }

    @Test
    func `a newer request can publish after an overlapping older success`() async {
        let store = Self.makeStore()
        let olderGate = StatusPublicationGate()
        let newerGate = StatusPublicationGate()
        var requests = 0
        store._test_providerStatusFetchOverride = { _ in
            requests += 1
            if requests == 1 {
                await olderGate.suspend()
                return Self.status(.none, description: "Older operational status")
            }
            await newerGate.suspend()
            return Self.status(.major, description: "Current incident")
        }

        let older = Task { await store.refreshProviderStatus(.opencode) }
        await olderGate.waitUntilStarted()
        let newer = Task { await store.refreshProviderStatus(.opencode) }
        await newerGate.waitUntilStarted()
        await olderGate.resume()
        await older.value
        #expect(store.statuses[.opencode]?.description == "Older operational status")
        await newerGate.resume()
        await newer.value

        #expect(store.statuses[.opencode]?.description == "Current incident")
        #expect(store.providerStatusHadIssue[.opencode] == true)
    }

    @Test
    func `an older success remains useful when a newer request fails`() async {
        let store = Self.makeStore()
        let gate = StatusPublicationGate()
        var requests = 0
        store._test_providerStatusFetchOverride = { _ in
            requests += 1
            if requests == 1 {
                await gate.suspend()
                return Self.status(.major, description: "Available incident")
            }
            throw URLError(.timedOut)
        }

        let older = Task { await store.refreshProviderStatus(.opencode) }
        await gate.waitUntilStarted()
        await store.refreshProviderStatus(.opencode)
        #expect(store.statuses[.opencode] == nil)
        await gate.resume()
        await older.value

        #expect(store.statuses[.opencode]?.description == "Available incident")
        #expect(store.providerStatusHadIssue[.opencode] == true)
    }

    @Test
    func `an older status failure cannot request a retry after newer success`() async {
        let store = Self.makeStore()
        let gate = StatusPublicationGate()
        var requests = 0
        store.startupConnectivityRetryRefreshActive = true
        store._test_providerStatusFetchOverride = { _ in
            requests += 1
            if requests == 1 {
                await gate.suspend()
                throw URLError(.notConnectedToInternet)
            }
            return Self.status(.major, description: "Current incident")
        }

        let older = Task { await store.refreshProviderStatus(.opencode) }
        await gate.waitUntilStarted()
        await store.refreshProviderStatus(.opencode)
        await gate.resume()
        await older.value

        #expect(store.statuses[.opencode]?.description == "Current incident")
        #expect(store.startupConnectivityRetryNeeded == false)
    }

    @Test
    func `status publication ordering is independent for each provider`() async {
        let store = Self.makeStore(providers: [.opencode, .claude])
        let gate = StatusPublicationGate()
        store._test_providerStatusFetchOverride = { provider in
            if provider == .opencode {
                await gate.suspend()
            }
            return Self.status(.major, description: provider.rawValue)
        }

        let codex = Task { await store.refreshProviderStatus(.opencode) }
        await gate.waitUntilStarted()
        await store.refreshProviderStatus(.claude)
        await gate.resume()
        await codex.value

        #expect(store.statuses[.opencode]?.description == "opencode")
        #expect(store.statuses[.claude]?.description == "claude")
    }

    @Test
    func `a later successful request can report a genuine recovery`() async {
        let store = Self.makeStore()
        store._test_providerStatusFetchOverride = { _ in
            Self.status(.major, description: "Incident")
        }
        await store.refreshProviderStatus(.opencode)
        #expect(store.providerStatusHadIssue[.opencode] == true)

        store._test_providerStatusFetchOverride = { _ in
            Self.status(.none, description: "Recovered")
        }
        await store.refreshProviderStatus(.opencode)

        #expect(store.statuses[.opencode]?.description == "Recovered")
        #expect(store.providerStatusHadIssue[.opencode] == false)
    }

    private static func makeStore(providers: Set<UsageProvider> = [.opencode]) -> UsageStore {
        let settings = testSettingsStore(
            suiteName: "ProviderStatusRefreshPublicationTests",
            userDefaults: InMemoryUserDefaults(),
            keychainAccessPolicy: .init(setDisabled: { _ in }, isExplicitlyDisabled: { true }))
        settings.providerDetectionCompleted = true
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = true
        settings.costUsageEnabled = false
        settings.providerStorageFootprintsEnabled = false
        enableTestProviders(providers, settings: settings)
        let store = UsageStore(
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
        store._test_providerRefreshOverride = { _ in }
        store._test_tokenUsageRefreshOverride = { _, _ in }
        return store
    }

    private static func status(_ indicator: ProviderStatusIndicator, description: String) -> ProviderStatus {
        ProviderStatus(indicator: indicator, description: description, updatedAt: nil)
    }
}

private actor StatusPublicationGate {
    private var started = false
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var release: CheckedContinuation<Void, Never>?

    func suspend() async {
        self.started = true
        self.startWaiter?.resume()
        self.startWaiter = nil
        await withCheckedContinuation { self.release = $0 }
    }

    func waitUntilStarted() async {
        guard !self.started else { return }
        await withCheckedContinuation { self.startWaiter = $0 }
    }

    func resume() {
        self.release?.resume()
        self.release = nil
    }
}
