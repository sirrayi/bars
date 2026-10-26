import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
@Suite(.serialized)
struct RequiredRefreshCoalescingTests {
    func makeSettingsStore(suite: String) throws -> SettingsStore {
        let settings = testSettingsStore(suiteName: suite, userDefaults: InMemoryUserDefaults())
        let metadata = try #require(ProviderDescriptorRegistry.metadata[.claude])
        settings.setProviderEnabled(provider: .claude, metadata: metadata, enabled: true)
        settings.providerDetectionCompleted = true
        return settings
    }

    func makeStore(settings: SettingsStore) -> UsageStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let environment = [
            "HOME": root.path,
            "XDG_CONFIG_HOME": root.appendingPathComponent(".config", isDirectory: true).path,
        ]
        return UsageStore(
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: environment)
    }

    @Test
    func `required refresh requests during a pass share one follow-up`() async throws {
        let settings = try self.makeSettingsStore(
            suite: "RequiredRefreshCoalescingTests-required-refresh-follow-up")
        settings.statusChecksEnabled = false
        settings.costUsageEnabled = false
        let store = self.makeStore(settings: settings)
        let providerGate = BlockingRequiredProviderRefresh()
        store._test_providerRefreshOverride = { _ in
            await providerGate.run(interaction: ProviderInteractionContext.current)
        }
        defer {
            store._test_providerRefreshOverride = nil
        }

        let firstRefresh = Task { @MainActor in
            await store.refreshForSettingsChange()
        }
        let didStartFirstPass = await providerGate.waitUntilStarted(count: 1)
        #expect(didStartFirstPass)
        guard didStartFirstPass else {
            firstRefresh.cancel()
            store.cancelRequiredRefresh()
            await providerGate.cancelAll()
            await firstRefresh.value
            return
        }

        var laterRefreshes: [Task<Void, Never>] = []
        for expectedGeneration in 2...4 {
            let task = Task { @MainActor in
                await store.refreshForSettingsChange()
            }
            laterRefreshes.append(task)
            for _ in 0..<100 where store.requiredRefreshRequestGeneration < expectedGeneration {
                await Task.yield()
            }
            #expect(store.requiredRefreshRequestGeneration == expectedGeneration)
        }
        #expect(await providerGate.startedCount() == 1)

        await providerGate.resumeNext()
        let didStartFollowUp = await providerGate.waitUntilStarted(count: 2)
        #expect(didStartFollowUp)
        guard didStartFollowUp else {
            firstRefresh.cancel()
            laterRefreshes.forEach { $0.cancel() }
            store.cancelRequiredRefresh()
            await providerGate.cancelAll()
            await firstRefresh.value
            for task in laterRefreshes {
                await task.value
            }
            return
        }
        #expect(store.requiredRefreshCompletedGeneration == 1)

        await providerGate.resumeNext()
        await firstRefresh.value
        for task in laterRefreshes {
            await task.value
        }
        try await Task.sleep(for: .milliseconds(50))

        #expect(await providerGate.startedCount() == 2)
        #expect(await providerGate.recordedInteractions() == [.background, .background])
        #expect(store.requiredRefreshCompletedGeneration == 4)
        #expect(store.requiredRefreshTask == nil)
        #expect(store.pendingRequiredRefreshRequest == nil)
    }

    @Test
    func `forced token tail excludes scheduled automatic token sequence`() async throws {
        let settings = try self.makeSettingsStore(
            suite: "RequiredRefreshCoalescingTests-forced-token-excludes-scheduled")
        settings.statusChecksEnabled = false
        settings.costUsageEnabled = true
        let store = self.makeStore(settings: settings)
        let tokenGate = BlockingForcedTokenRefresh()
        store._test_providerRefreshOverride = { _ in }
        store._test_tokenUsageRefreshOverride = { provider, force in
            await tokenGate.run(
                provider: provider,
                force: force,
                interaction: ProviderInteractionContext.current,
                refreshPhase: ProviderRefreshContext.current,
                browserRetryAllowed: false)
        }
        defer {
            store._test_providerRefreshOverride = nil
            store._test_tokenUsageRefreshOverride = nil
        }

        await store.refresh(enrichmentMode: .forcedBackground)
        #expect(await tokenGate.waitUntilStarted(count: 1))

        store.scheduleTokenRefreshForTesting()
        try await Task.sleep(for: .milliseconds(100))
        #expect(await tokenGate.recordedCalls().count == 1)

        await tokenGate.resumeNext()
        await store.awaitForcedRefreshEnrichment()

        let calls = await tokenGate.recordedCalls()
        #expect(calls.count == 1)
        #expect(calls.first?.force == true)
        #expect(!store.hasForcedRefreshEnrichmentInFlight)
    }
}

private actor BlockingRequiredProviderRefresh {
    private var interactions: [ProviderInteraction] = []
    private var continuations: [(id: UUID, continuation: CheckedContinuation<Void, Never>)] = []

    func run(interaction: ProviderInteraction) async {
        let id = UUID()
        self.interactions.append(interaction)
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if Task.isCancelled {
                    continuation.resume()
                } else {
                    self.continuations.append((id: id, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancel(id: id) }
        }
    }

    func waitUntilStarted(count: Int, timeout: Duration = .seconds(5)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while self.interactions.count < count {
            if ContinuousClock.now >= deadline {
                return false
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    func startedCount() -> Int {
        self.interactions.count
    }

    func recordedInteractions() -> [ProviderInteraction] {
        self.interactions
    }

    func resumeNext() {
        guard !self.continuations.isEmpty else { return }
        self.continuations.removeFirst().continuation.resume()
    }

    func cancelAll() {
        let continuations = self.continuations
        self.continuations.removeAll()
        continuations.forEach { $0.continuation.resume() }
    }

    private func cancel(id: UUID) {
        guard let index = self.continuations.firstIndex(where: { $0.id == id }) else { return }
        self.continuations.remove(at: index).continuation.resume()
    }
}

actor BlockingForcedTokenRefresh {
    struct Call: Sendable {
        let provider: UsageProvider
        let force: Bool
        let interaction: ProviderInteraction
        let refreshPhase: ProviderRefreshPhase
        let browserRetryAllowed: Bool
    }

    private var calls: [Call] = []
    private var continuations: [(id: UUID, continuation: CheckedContinuation<Void, Never>)] = []

    func run(
        provider: UsageProvider,
        force: Bool,
        interaction: ProviderInteraction,
        refreshPhase: ProviderRefreshPhase,
        browserRetryAllowed: Bool) async
    {
        let id = UUID()
        self.calls.append(Call(
            provider: provider,
            force: force,
            interaction: interaction,
            refreshPhase: refreshPhase,
            browserRetryAllowed: browserRetryAllowed))
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if Task.isCancelled {
                    continuation.resume()
                } else {
                    self.continuations.append((id: id, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancel(id: id) }
        }
    }

    @discardableResult
    func waitUntilStarted(count: Int, timeout: Duration = .seconds(5)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while self.calls.count < count {
            if ContinuousClock.now >= deadline {
                return false
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    func resumeNext() {
        guard !self.continuations.isEmpty else { return }
        self.continuations.removeFirst().continuation.resume()
    }

    func recordedCalls() -> [Call] {
        self.calls
    }

    private func cancel(id: UUID) {
        guard let index = self.continuations.firstIndex(where: { $0.id == id }) else { return }
        self.continuations.remove(at: index).continuation.resume()
    }
}
