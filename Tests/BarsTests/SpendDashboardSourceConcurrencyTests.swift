import BarsCore
import Foundation
import Observation
import Testing
@testable import Bars

@MainActor
struct SpendDashboardSourceConcurrencyTests {
    @Test
    func `gate readiness tolerates a delayed producer`() async throws {
        let gate = SpendDashboardPendingLoads<CostUsageTokenSnapshot>()
        defer { gate.close() }
        let producer = Task {
            try await Task.sleep(for: .seconds(2))
            return try await gate.load()
        }

        defer { producer.cancel() }
        try await gate.waitForPendingCount(1)
        #expect(gate.isSuspended)
        gate.resume(returning: Self.input(cost: 5).snapshot)
        let snapshot = try await producer.value
        #expect(snapshot.last30DaysCostUSD == 5)
    }

    @Test
    func `request revision captured before coalesced update cannot publish stale inputs`() async throws {
        let requestGate = SpendDashboardPendingLoads<Void>()
        defer { requestGate.close() }
        let recorder = SpendDashboardRequestRecorder()
        let initial = SpendDashboardConfiguration(
            costUsageEnabled: true,
            providerIDs: [UsageProvider.claude.rawValue],
            sourceOwnershipFingerprints: ["claude:owner"],
            sourceRevisions: ["R"])
        let replacement = SpendDashboardConfiguration(
            costUsageEnabled: true,
            providerIDs: [UsageProvider.claude.rawValue],
            sourceOwnershipFingerprints: ["claude:owner"],
            sourceRevisions: ["R+1"])
        let requestSequence = SpendDashboardRequestSequence(
            [
                .init(configuration: initial, capturedInputs: [Self.input(provider: .claude, cost: 1)]),
                .init(configuration: replacement, capturedInputs: [Self.input(provider: .claude, cost: 2)]),
                .init(configuration: replacement, capturedInputs: [Self.input(provider: .claude, cost: 2)]),
            ],
            suspendAt: 0,
            gate: requestGate)
        let controller = SpendDashboardController(
            requestBuilder: { mode in await requestSequence.next(mode: mode) },
            loader: { request in
                await recorder.record(request)
                return SpendDashboardLoadResult(inputs: request.capturedInputs, failedSourceIDs: [])
            })

        controller.update(configuration: initial, force: true)
        try await requestGate.waitForPendingCount(1)
        controller.update(configuration: replacement)
        requestGate.resume()
        try await Self.waitUntil { !controller.isRefreshing }

        #expect(controller.configuration == replacement)
        #expect(controller.generation == 2)
        #expect(controller.model.groups.first?.totalCost == 2)
        #expect(requestSequence.modes == [.forceRefresh, .captureOnly])
        #expect(await recorder.configurations == [initial])
        #expect(await recorder.forces == [true])
    }

    @Test
    func `forced builder owner mismatch reruns replacement builder and rejects cached request`() async throws {
        let requestGate = SpendDashboardPendingLoads<Void>()
        defer { requestGate.close() }
        let recorder = SpendDashboardRequestRecorder()
        let initial = SpendDashboardConfiguration(
            costUsageEnabled: true,
            providerIDs: [UsageProvider.opencode.rawValue, UsageProvider.claude.rawValue],
            sourceOwnershipFingerprints: ["claude:owner-one"],
            sourceRevisions: ["R"])
        let replacement = SpendDashboardConfiguration(
            costUsageEnabled: true,
            providerIDs: [UsageProvider.opencode.rawValue, UsageProvider.claude.rawValue],
            sourceOwnershipFingerprints: ["claude:owner-two"],
            sourceRevisions: ["R+1"])
        let cachedInput = Self.input(provider: .claude, cost: 1)
        let freshInput = Self.input(provider: .claude, cost: 3)
        let requestSequence = SpendDashboardRequestSequence(
            [
                .init(configuration: replacement, capturedInputs: [cachedInput]),
                .init(configuration: replacement, capturedInputs: [freshInput]),
                .init(configuration: replacement, capturedInputs: [freshInput]),
            ],
            suspendAt: 1,
            gate: requestGate)
        let controller = SpendDashboardController(
            requestBuilder: { mode in await requestSequence.next(mode: mode) },
            loader: { request in
                await recorder.record(request)
                return SpendDashboardLoadResult(inputs: request.capturedInputs, failedSourceIDs: [])
            })

        controller.update(configuration: initial, force: true)
        try await requestGate.waitForPendingCount(1)

        #expect(controller.configuration == replacement)
        #expect(controller.generation == 2)
        #expect(controller.model.groups.isEmpty)
        #expect(requestSequence.modes == [.forceRefresh, .forceRefresh])
        #expect(await recorder.configurations.isEmpty)

        requestGate.resume()
        try await Self.waitUntil { !controller.isRefreshing }

        #expect(controller.configuration == replacement)
        #expect(controller.generation == 3)
        #expect(controller.model.groups.first?.totalCost == 3)
        #expect(requestSequence.modes == [.forceRefresh, .forceRefresh, .captureOnly])
        #expect(await recorder.configurations == [replacement])
        #expect(await recorder.forces == [true])
    }

    @Test
    func `ownership replacement while force builder is pending reruns builder and loader forced`() async throws {
        let requestGate = SpendDashboardPendingLoads<Void>()
        defer { requestGate.close() }
        let recorder = SpendDashboardRequestRecorder()
        let initial = SpendDashboardConfiguration(
            costUsageEnabled: true,
            providerIDs: [UsageProvider.opencode.rawValue, UsageProvider.claude.rawValue],
            sourceOwnershipFingerprints: ["claude:owner-one"],
            sourceRevisions: ["R"])
        let replacement = SpendDashboardConfiguration(
            costUsageEnabled: true,
            providerIDs: [UsageProvider.opencode.rawValue, UsageProvider.claude.rawValue],
            sourceOwnershipFingerprints: ["claude:owner-two"],
            sourceRevisions: ["R+1"])
        let replacementInput = Self.input(provider: .opencode, cost: 4)
        let requestSequence = SpendDashboardRequestSequence(
            [
                .init(configuration: initial, capturedInputs: [Self.input(provider: .opencode, cost: 1)]),
                .init(configuration: replacement, capturedInputs: [replacementInput]),
                .init(configuration: replacement, capturedInputs: [replacementInput]),
            ],
            suspendAt: 0,
            gate: requestGate)
        let controller = SpendDashboardController(
            requestBuilder: { mode in await requestSequence.next(mode: mode) },
            loader: { request in
                await recorder.record(request)
                return SpendDashboardLoadResult(inputs: request.capturedInputs, failedSourceIDs: [])
            })

        controller.update(configuration: initial, force: true)
        try await requestGate.waitForPendingCount(1)
        controller.update(configuration: replacement)
        try await Self.waitUntil { !controller.isRefreshing }
        requestGate.resume()
        await Task.yield()

        #expect(controller.configuration == replacement)
        #expect(controller.generation == 3)
        #expect(controller.model.groups.first?.totalCost == 4)
        #expect(requestSequence.modes == [.forceRefresh, .forceRefresh, .captureOnly])
        #expect(await recorder.configurations == [replacement])
        #expect(await recorder.forces == [true])
    }

    @Test
    func `ownership replacement after force builder completes reruns builder and loader forced`() async throws {
        let loaderGate = SpendDashboardResultBatchGate()
        defer { loaderGate.close() }
        let initial = SpendDashboardConfiguration(
            costUsageEnabled: true,
            providerIDs: [UsageProvider.opencode.rawValue, UsageProvider.claude.rawValue],
            sourceOwnershipFingerprints: ["claude:owner-one"],
            sourceRevisions: ["R"])
        let replacement = SpendDashboardConfiguration(
            costUsageEnabled: true,
            providerIDs: [UsageProvider.opencode.rawValue, UsageProvider.claude.rawValue],
            sourceOwnershipFingerprints: ["claude:owner-two"],
            sourceRevisions: ["R+1"])
        let requestSequence = SpendDashboardRequestSequence([
            .init(configuration: initial),
            .init(configuration: replacement),
            .init(
                configuration: replacement,
                capturedInputs: [Self.input(provider: .opencode, cost: 5)]),
        ])
        let controller = SpendDashboardController(
            requestBuilder: { mode in await requestSequence.next(mode: mode) },
            loader: { request in await loaderGate.load(request) })

        controller.update(configuration: initial, force: true)
        try await loaderGate.waitForPendingCount(1)
        controller.update(configuration: replacement)
        try await loaderGate.waitForPendingCount(2)

        #expect(requestSequence.modes == [.forceRefresh, .forceRefresh])
        #expect(loaderGate.configurations == [initial, replacement])
        #expect(loaderGate.forces == [true, true])

        loaderGate.resume(
            at: 1,
            result: SpendDashboardLoadResult(
                inputs: [Self.input(provider: .opencode, cost: 5)],
                failedSourceIDs: []))
        try await Self.waitUntil { !controller.isRefreshing }
        loaderGate.resume(
            at: 0,
            result: SpendDashboardLoadResult(
                inputs: [Self.input(provider: .opencode, cost: 99)],
                failedSourceIDs: []))
        await Task.yield()

        #expect(controller.configuration == replacement)
        #expect(controller.generation == 3)
        #expect(controller.model.groups.first?.totalCost == 5)
    }

    @Test
    func `ordinary in flight same owner revision churn does not restart load`() async throws {
        let loaderGate = SpendDashboardResultBatchGate()
        defer { loaderGate.close() }
        let initial = SpendDashboardConfiguration(
            costUsageEnabled: true,
            providerIDs: [UsageProvider.opencode.rawValue],
            sourceRevisions: ["first"])
        let replacement = SpendDashboardConfiguration(
            costUsageEnabled: true,
            providerIDs: [UsageProvider.opencode.rawValue],
            sourceRevisions: ["second"])
        let controllerBox = SpendDashboardControllerBox()
        let controller = SpendDashboardController(
            requestBuilder: { mode in
                let configuration = controllerBox.controller?.configuration ?? initial
                return SpendDashboardLoadRequest(
                    configuration: configuration,
                    capturedInputs: [],
                    unavailableSourceIDs: [],
                    now: Date(timeIntervalSince1970: 1_784_179_200),
                    force: mode.forcesLoader)
            },
            loader: { request in await loaderGate.load(request) })
        controllerBox.controller = controller

        controller.update(configuration: initial)
        try await loaderGate.waitForPendingCount(1)
        let inFlightGeneration = controller.generation
        #expect(controller.isRefreshing)

        controller.update(configuration: replacement)
        #expect(controller.generation == inFlightGeneration)
        #expect(controller.configuration == replacement)
        #expect(controller.publication.configuration == replacement)
        #expect(controller.publication.isRefreshing)

        loaderGate.resume(
            result: SpendDashboardLoadResult(
                inputs: [Self.input(provider: .opencode, cost: 7)],
                failedSourceIDs: []))
        try await loaderGate.waitForPendingCount(1)
        loaderGate.resume(
            result: SpendDashboardLoadResult(
                inputs: [Self.input(provider: .opencode, cost: 7)],
                failedSourceIDs: []))
        try await Self.waitUntil { !controller.isRefreshing }

        #expect(controller.generation == inFlightGeneration + 1)
        #expect(controller.configuration == replacement)
        #expect(controller.model.groups.first?.totalCost == 7)
    }

    private static func input(
        id: String? = nil,
        provider: UsageProvider = .opencode,
        cost: Double,
        displayName: String? = nil) -> SpendDashboardModel.ProviderInput
    {
        let entry = CostUsageDailyReport.Entry(
            date: "2026-07-15",
            inputTokens: nil,
            outputTokens: nil,
            totalTokens: 10,
            costUSD: cost,
            modelsUsed: nil,
            modelBreakdowns: nil)
        let snapshot = CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: 10,
            last30DaysCostUSD: cost,
            daily: [entry],
            updatedAt: Date(timeIntervalSince1970: 1_784_179_200))
        return SpendDashboardModel.ProviderInput(
            id: id,
            provider: provider,
            displayName: displayName ?? provider.rawValue,
            modelProviderName: nil,
            snapshot: snapshot)
    }

    private static func waitUntil(_ condition: @escaping @MainActor () -> Bool) async throws {
        try await SpendDashboardStateWait.until(condition)
    }
}

extension SpendDashboardSourceConcurrencyTests {
    @Test
    func `gate readiness observes an already pending producer and can be reused`() async throws {
        let gate = SpendDashboardPendingLoads<Int>()
        defer { gate.close() }
        for value in [1, 2] {
            let producer = Task { try await gate.load() }
            try await Self.waitUntil { gate.pendingCount == 1 }
            try await gate.waitForPendingCount(1)
            #expect(gate.readinessWaiterCount == 0)
            gate.resume(returning: value)
            #expect(try await producer.value == value)
            #expect(gate.pendingCount == 0)
        }
    }

    @Test
    func `gate readiness timeout drains pending loads and rejects late arrivals`() async throws {
        let gate = SpendDashboardPendingLoads<Int>()
        defer { gate.close() }
        let producer = Task { try await gate.load() }
        try await gate.waitForPendingCount(1)

        let started = ContinuousClock.now
        await #expect(throws: SpendDashboardWaitError.timedOut) {
            try await gate.waitForPendingCount(2, timeout: .milliseconds(20))
        }
        #expect(ContinuousClock.now - started >= .milliseconds(20))
        await #expect(throws: SpendDashboardWaitError.closed) { try await producer.value }
        await #expect(throws: SpendDashboardWaitError.closed) { try await gate.load() }
        #expect(gate.isClosed)
        #expect(gate.pendingCount == 0)
        #expect(gate.readinessWaiterCount == 0)
    }

    @Test
    func `cancelling a registered readiness wait drains its producer`() async throws {
        let gate = SpendDashboardPendingLoads<Int>()
        defer { gate.close() }
        let producer = Task { try await gate.load() }
        try await gate.waitForPendingCount(1)
        let waiter = Task { try await gate.waitForPendingCount(2) }
        try await Self.waitUntil { gate.readinessWaiterCount == 1 }
        waiter.cancel()

        await #expect(throws: CancellationError.self) { try await waiter.value }
        await #expect(throws: SpendDashboardWaitError.closed) { try await producer.value }
        #expect(gate.isClosed)
        #expect(gate.pendingCount == 0)
        #expect(gate.readinessWaiterCount == 0)
    }

    @Test
    func `readiness cancellation before registration closes the gate`() async {
        let gate = SpendDashboardPendingLoads<Int>()
        defer { gate.close() }
        let waiter = Task { try await gate.waitForPendingCount(1) }
        waiter.cancel()

        await #expect(throws: CancellationError.self) { try await waiter.value }
        await #expect(throws: SpendDashboardWaitError.closed) { try await gate.load() }
        #expect(gate.pendingCount == 0)
        #expect(gate.readinessWaiterCount == 0)
    }

    @Test
    func `producer cancellation preserves the deliberate stale completion gate`() async throws {
        let gate = SpendDashboardPendingLoads<Int>()
        defer { gate.close() }
        let producer = Task { try await gate.load() }
        try await gate.waitForPendingCount(1)
        producer.cancel()
        #expect(gate.pendingCount == 1)
        gate.resume(returning: 42)
        #expect(try await producer.value == 42)
        #expect(gate.pendingCount == 0)
    }

    @Test
    func `throwing test scope drains multiple pending loads`() async throws {
        let gate = SpendDashboardPendingLoads<Int>()
        let first = Task { try await gate.load() }
        let second = Task { try await gate.load() }
        await #expect(throws: SpendDashboardSyntheticError.failed) {
            defer { gate.close() }
            try await gate.waitForPendingCount(2)
            throw SpendDashboardSyntheticError.failed
        }

        await #expect(throws: SpendDashboardWaitError.closed) { try await first.value }
        await #expect(throws: SpendDashboardWaitError.closed) { try await second.value }
        gate.close()
        #expect(gate.pendingCount == 0)
        #expect(gate.readinessWaiterCount == 0)
    }

    @Test
    func `state observation timeout releases its captured state`() async {
        weak var released: SpendDashboardPendingLoads<Int>?
        await #expect(throws: SpendDashboardWaitError.timedOut) {
            let gate = SpendDashboardPendingLoads<Int>()
            released = gate
            try await SpendDashboardStateWait.until(timeout: .milliseconds(20)) {
                gate.isClosed
            }
        }
        #expect(released == nil)
    }
}

private enum SpendDashboardSyntheticError: Error, Equatable {
    case failed
}

@MainActor
private final class SpendDashboardRequestSequence {
    struct Item {
        let configuration: SpendDashboardConfiguration
        let capturedInputs: [SpendDashboardModel.ProviderInput]

        init(configuration: SpendDashboardConfiguration, capturedInputs: [SpendDashboardModel.ProviderInput] = []) {
            self.configuration = configuration
            self.capturedInputs = capturedInputs
        }
    }

    private var items: [Item]
    private let suspendAt: Int?
    private let gate: SpendDashboardPendingLoads<Void>?
    private var index = 0
    private(set) var modes: [SpendDashboardRequestBuildMode] = []

    init(
        _ items: [Item],
        suspendAt: Int? = nil,
        gate: SpendDashboardPendingLoads<Void>? = nil)
    {
        self.items = items
        self.suspendAt = suspendAt
        self.gate = gate
    }

    func next(mode: SpendDashboardRequestBuildMode) async -> SpendDashboardLoadRequest {
        let item = self.items.removeFirst()
        let index = self.index
        self.index += 1
        self.modes.append(mode)
        if index == self.suspendAt {
            await self.gate?.suspend()
        }
        return SpendDashboardLoadRequest(
            configuration: item.configuration,
            capturedInputs: item.capturedInputs,
            unavailableSourceIDs: [],
            now: Date(timeIntervalSince1970: 1_784_179_200),
            force: mode.forcesLoader)
    }
}

private actor SpendDashboardRequestRecorder {
    private(set) var configurations: [SpendDashboardConfiguration] = []
    private(set) var forces: [Bool] = []

    func record(_ request: SpendDashboardLoadRequest) {
        self.configurations.append(request.configuration)
        self.forces.append(request.force)
    }
}

private enum SpendDashboardWaitError: Error, Equatable {
    case timedOut
    case closed
}

@MainActor
private final class SpendDashboardTestSignal<Value: Sendable> {
    private var result: Result<Value, any Error>?
    private var continuation: CheckedContinuation<Value, any Error>?
    private var watchdog: Task<Void, Never>?

    func resolve(_ result: Result<Value, any Error>) {
        guard self.result == nil else { return }
        self.result = result
        self.watchdog?.cancel()
        self.watchdog = nil
        let continuation = self.continuation
        self.continuation = nil
        continuation?.resume(with: result)
    }

    func wait(timeout: Duration? = .seconds(5), ignoringCancellation: Bool = false) async throws -> Value {
        try await withTaskCancellationHandler {
            if !ignoringCancellation {
                try Task.checkCancellation()
            }
            if let result = self.result {
                return try result.get()
            }
            let deadline = timeout.map { ContinuousClock.now + $0 }
            return try await withCheckedThrowingContinuation { continuation in
                precondition(self.continuation == nil)
                self.continuation = continuation
                guard let deadline else { return }
                self.watchdog = Task { @MainActor [weak self] in
                    do { try await Task.sleep(until: deadline, clock: .continuous) } catch { return }
                    self?.resolve(.failure(SpendDashboardWaitError.timedOut))
                }
            }
        } onCancel: {
            if !ignoringCancellation {
                Task { @MainActor in self.resolve(.failure(CancellationError())) }
            }
        }
    }
}

@MainActor
final class SpendDashboardStateWait {
    private var condition: (@MainActor () -> Bool)?
    private let signal = SpendDashboardTestSignal<Void>()

    private init(_ condition: @escaping @MainActor () -> Bool) {
        self.condition = condition
    }

    static func until(
        timeout: Duration = .seconds(5),
        _ condition: @escaping @MainActor () -> Bool) async throws
    {
        let wait = Self(condition)
        defer { wait.condition = nil }
        wait.observe()
        try await wait.signal.wait(timeout: timeout)
    }

    private func observe() {
        guard let condition = self.condition else { return }
        if withObservationTracking(condition, onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observe() }
        }) {
            self.signal.resolve(.success(()))
        }
    }
}

@MainActor
@Observable
final class SpendDashboardPendingLoads<Value: Sendable> {
    private var pending: [SpendDashboardTestSignal<Value>] = []
    private(set) var isClosed = false
    private(set) var readinessWaiterCount = 0
    /// An expired release fails the parked producer, which production treats as a real error.
    /// Pass nil when the test does unbounded real work before releasing; close() then owns the release.
    private let releaseTimeout: Duration?

    init(releaseTimeout: Duration? = .seconds(5)) {
        self.releaseTimeout = releaseTimeout
    }

    var pendingCount: Int {
        self.pending.count
    }

    var isSuspended: Bool {
        !self.pending.isEmpty
    }

    func load() async throws -> Value {
        guard !self.isClosed else { throw SpendDashboardWaitError.closed }
        let signal = SpendDashboardTestSignal<Value>()
        self.pending.append(signal)
        defer { self.pending.removeAll { $0 === signal } }
        do {
            // Stale-owner tests deliberately complete cancelled producers. Only the test owns their release.
            return try await signal.wait(timeout: self.releaseTimeout, ignoringCancellation: true)
        } catch {
            if case SpendDashboardWaitError.timedOut = error {
                Issue.record("Timed out waiting for the test to release a dashboard load")
            }
            self.close()
            throw error
        }
    }

    func waitForPendingCount(_ count: Int, timeout: Duration = .seconds(5)) async throws {
        self.readinessWaiterCount += 1
        defer { self.readinessWaiterCount -= 1 }
        do {
            try await SpendDashboardStateWait.until(timeout: timeout) {
                self.pendingCount == count || self.isClosed
            }
            guard !self.isClosed else { throw SpendDashboardWaitError.closed }
        } catch {
            self.close()
            throw error
        }
    }

    func resume(at index: Int = 0, returning value: Value) {
        guard self.pending.indices.contains(index) else {
            Issue.record("Cannot resume a dashboard load before it is pending")
            return
        }
        self.pending.remove(at: index).resolve(.success(value))
    }

    func close() {
        self.isClosed = true
        let pending = self.pending
        self.pending.removeAll()
        for signal in pending {
            signal.resolve(.failure(SpendDashboardWaitError.closed))
        }
    }
}

extension SpendDashboardPendingLoads where Value == Void {
    func suspend() async {
        _ = try? await self.load()
    }

    func resume() {
        self.resume(returning: ())
    }
}

@MainActor
private final class SpendDashboardResultBatchGate {
    private var requests: [SpendDashboardLoadRequest] = []
    private let pending = SpendDashboardPendingLoads<SpendDashboardLoadResult>()

    var pendingCount: Int {
        self.pending.pendingCount
    }

    var configurations: [SpendDashboardConfiguration] {
        self.requests.map(\.configuration)
    }

    var forces: [Bool] {
        self.requests.map(\.force)
    }

    func load(_ request: SpendDashboardLoadRequest) async -> SpendDashboardLoadResult {
        self.requests.append(request)
        do {
            return try await self.pending.load()
        } catch {
            // A readiness failure already fails the test; closing its scope must still drain controller tasks.
            return SpendDashboardLoadResult(inputs: [], failedSourceIDs: [])
        }
    }

    func waitForPendingCount(_ count: Int) async throws {
        try await self.pending.waitForPendingCount(count)
    }

    func resume(at index: Int = 0, result: SpendDashboardLoadResult) {
        self.pending.resume(at: index, returning: result)
    }

    func close() {
        self.pending.close()
    }
}

@MainActor
private final class SpendDashboardControllerBox {
    var controller: SpendDashboardController?
}
