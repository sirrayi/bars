import BarsCore
import Foundation
import Testing
@testable import Bars

@MainActor
@Suite(.serialized)
struct SpendDashboardPublicationTests {
    @Test
    func `shared source observation follows regular Devin publication and bucket ownership`() async {
        let settings = testSettingsStore(suiteName: "SpendDashboardPublicationTests-source-observation")
        settings.costUsageEnabled = true
        for provider in UsageProvider.allCases {
            guard let metadata = ProviderRegistry.shared.metadata[provider] else { continue }
            settings.setProviderEnabled(
                provider: provider,
                metadata: metadata,
                enabled: provider == .devin || provider == .claude)
        }
        settings.costUsageBucketTimeZoneIdentifier = "UTC"
        // Isolate from any real ~/.devin corpus: this branch gives the spend dashboard longer
        // catch-up slices, so a developer-machine corpus can delay the shared publication past
        // the wait deadline even though the observation semantics are unchanged.
        let isolatedHome = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let environment = ["HOME": isolatedHome.path]
        defer {
            try? FileManager.default.removeItem(at: isolatedHome)
        }
        let store = UsageStore(
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: environment)
        // Provider-specific by design: claude stays enabled so ownership fingerprints cover an
        // independent provider, but its refresh is pinned to one confirmed-empty publication so the
        // source-revision baseline cannot depend on live network behavior or repeat refreshes.
        // The publication is seeded before the first configuration snapshot, and the override only
        // fires once, so every recompute in this test observes the same `claude:empty:1` revision.
        var claudeSpendSnapshotPinned = false
        store._test_tokenUsageRefreshOverride = { provider, _ in
            guard provider == .claude, !claudeSpendSnapshotPinned else { return }
            claudeSpendSnapshotPinned = true
            store._setSpendDashboardTokenSnapshotForTesting(nil, for: .claude)
        }
        defer { store._test_tokenUsageRefreshOverride = nil }
        store._setSpendDashboardTokenSnapshotForTesting(nil, for: .claude)
        claudeSpendSnapshotPinned = true
        let initial = SpendDashboardSource.configuration(settings: settings, store: store)
        store.startSharedSpendDashboardPublication()
        defer { store.stopSharedSpendDashboardPublication() }
        await Self.waitUntil {
            store.spendDashboardPublication.configuration?.sourceRevisions == initial.sourceRevisions
        }

        store._setTokenSnapshotForTesting(
            Self.input(id: "devin", provider: .devin, cost: 1).snapshot,
            provider: .devin)
        let afterRegularDevinPublication = SpendDashboardSource.configuration(settings: settings, store: store)
        await Self.waitUntil {
            store.spendDashboardPublication.configuration?.sourceRevisions ==
                afterRegularDevinPublication.sourceRevisions
        }

        #expect(afterRegularDevinPublication.sourceRevisions != initial.sourceRevisions)
        #expect(store.spendDashboardPublication.configuration?.sourceRevisions ==
            afterRegularDevinPublication.sourceRevisions)

        settings.costUsageBucketTimeZoneIdentifier = "Pacific/Kiritimati"
        let rebucketed = SpendDashboardSource.configuration(settings: settings, store: store)
        await Self.waitUntil {
            store.spendDashboardPublication.configuration?.menuOwnershipFingerprint ==
                rebucketed.menuOwnershipFingerprint
        }

        #expect(rebucketed.menuOwnershipFingerprint != afterRegularDevinPublication.menuOwnershipFingerprint)
        #expect(rebucketed.sourceOwnershipFingerprints != afterRegularDevinPublication.sourceOwnershipFingerprints)
        #expect(store.spendDashboardPublication.configuration?.menuOwnershipFingerprint ==
            rebucketed.menuOwnershipFingerprint)
    }

    @Test
    func `synchronizes independent snapshot publications`() async {
        let settings = testSettingsStore(suiteName: "SpendDashboardPublicationTests-independent-sync")
        settings.costUsageEnabled = true
        for provider in UsageProvider.allCases {
            guard let metadata = ProviderRegistry.shared.metadata[provider] else { continue }
            settings.setProviderEnabled(
                provider: provider,
                metadata: metadata,
                enabled: provider == .claude)
        }
        settings.costUsageBucketTimeZoneIdentifier = "UTC"
        let store = UsageStore(
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])

        // Seed before observation starts so the post-start publication below has a distinct
        // publication revision. Codex stays disabled: the regular publisher must not mask the
        // independent synchronization under test.
        store._setSpendDashboardTokenSnapshotForTesting(nil, for: .claude)
        store.startSharedSpendDashboardPublication()
        defer { store.stopSharedSpendDashboardPublication() }
        let seeded = SpendDashboardSource.configuration(settings: settings, store: store)
        await Self.waitUntil {
            store.spendDashboardPublication.configuration == seeded
        }

        let refreshedSnapshot = Self.input(id: "claude", provider: .claude, cost: 2.5).snapshot
        store._setSpendDashboardTokenSnapshotForTesting(refreshedSnapshot, for: .claude)

        // The independent publication boundary must schedule the shared-dashboard sync itself;
        // removing that call leaves this assertion green only if the regular publisher is used.
        #expect(store._test_hasPendingSpendDashboardTokenPublicationSync)

        let synchronized = SpendDashboardSource.configuration(settings: settings, store: store)
        #expect(synchronized != seeded)
        await Self.waitUntil {
            store.spendDashboardPublication.configuration == synchronized &&
                store.spendDashboardPublication.inputs.contains { $0.id == "claude" }
        }

        #expect(store.spendDashboardPublication.inputs.first { $0.id == "claude" }?
            .snapshot.last30DaysCostUSD == 2.5)
    }

    @Test
    func `usage store owns one shared controller and mirrors its publication`() {
        let settings = testSettingsStore(suiteName: "SpendDashboardPublicationTests-shared-owner")
        let store = UsageStore(
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
        let first = store.sharedSpendDashboardController()
        let second = store.sharedSpendDashboardController()

        #expect(first === second)

        first.update(configuration: SpendDashboardConfiguration(
            costUsageEnabled: false,
            providerIDs: []))

        #expect(store.spendDashboardPublication.revision > 0)
        #expect(store.spendDashboardPublication.configuration?.costUsageEnabled == false)
    }

    @Test
    func `failed refresh publishes retained input as stale last known`() async throws {
        let initialConfiguration = Self.configuration(revision: "claude:first")
        let replacementConfiguration = Self.configuration(revision: "claude:second")
        let script = SpendDashboardPublicationScript(
            requests: [
                Self.request(configuration: initialConfiguration),
                Self.request(configuration: replacementConfiguration, unavailableSourceIDs: ["claude"]),
            ],
            results: [
                SpendDashboardLoadResult(
                    inputs: [Self.input(id: "claude", provider: .claude, cost: 3)],
                    failedSourceIDs: []),
                SpendDashboardLoadResult(inputs: [], failedSourceIDs: ["claude"]),
            ])
        let controller = SpendDashboardController(
            requestBuilder: { mode in await script.nextRequest(mode: mode) },
            loader: { request in await script.nextResult(request: request) })

        controller.update(configuration: initialConfiguration)
        await Self.waitUntil { !controller.isRefreshing }
        controller.update(configuration: replacementConfiguration)
        await Self.waitUntil { !controller.isRefreshing && controller.generation == 2 }

        let source = try #require(controller.publication.sources.first { $0.id == "claude" })
        #expect(source.state == .staleLastKnown)
        #expect(controller.publication.inputs.first { $0.id == "claude" }?.snapshot.last30DaysCostUSD == 3)
        let overview = controller.publication.model(
            requestedDays: 30,
            now: Self.now,
            calendar: Self.calendar,
            preferredCurrencyCode: "USD")
        #expect(overview.groups.isEmpty)
    }

    @Test
    func `empty and unavailable catalogs have distinct summary copy`() {
        let model = SpendDashboardModel(requestedDays: 30, groups: [])
        let empty = OverviewSpendSummary(
            model: model,
            providerCount: 2,
            knownCostProviderCount: 2,
            knownTokenProviderCount: 2)
        let unavailable = OverviewSpendSummary(
            model: model,
            providerCount: 2,
            knownCostProviderCount: 0,
            knownTokenProviderCount: 0)

        #expect(empty.primarySpendText == "No usage yet")
        #expect(unavailable.primarySpendText == "Spend unavailable")
    }

    @Test
    func `overview projection is synchronous and reuses published inputs without loading`() async {
        let fixture = Self.fixture()
        let calls = SpendDashboardPublicationLoadCounter()
        let controller = SpendDashboardController(
            requestBuilder: { _ in fixture.request },
            loader: { _ in
                await calls.recordLoad()
                return fixture.result
            })

        controller.update(configuration: fixture.request.configuration)
        await Self.waitUntil { !controller.isRefreshing }
        let callsBeforeProjection = await calls.count

        let model = controller.publication.model(
            requestedDays: 30,
            now: Self.now,
            calendar: Self.calendar,
            preferredCurrencyCode: "USD",
            providerScope: [.devin])
        let providerIDs = model.groups.flatMap { group in
            group.providers.map(\.id)
        }

        #expect(await calls.count == callsBeforeProjection)
        #expect(Set(providerIDs) == ["devin:first", "devin:second"])
        #expect(model.groups.first?.totalCost == 5)
    }

    private static func configuration(revision: String) -> SpendDashboardConfiguration {
        SpendDashboardConfiguration(
            costUsageEnabled: true,
            providerIDs: [UsageProvider.claude.rawValue],
            sourceOwnershipFingerprints: ["claude:stable-owner"],
            sourceRevisions: [revision])
    }

    private static func request(
        configuration: SpendDashboardConfiguration,
        unavailableSourceIDs: Set<String> = []) -> SpendDashboardLoadRequest
    {
        SpendDashboardLoadRequest(
            configuration: configuration,
            capturedInputs: [],
            unavailableSourceIDs: unavailableSourceIDs,
            now: self.now,
            force: false)
    }

    private static func input(
        id: String,
        provider: UsageProvider,
        cost: Double?) -> SpendDashboardModel.ProviderInput
    {
        SpendDashboardModel.ProviderInput(
            id: id,
            provider: provider,
            displayName: provider.rawValue,
            snapshot: CostUsageTokenSnapshot(
                sessionTokens: nil,
                sessionCostUSD: nil,
                last30DaysTokens: 10,
                last30DaysCostUSD: cost,
                currencyCode: "USD",
                daily: [
                    CostUsageDailyReport.Entry(
                        date: "2026-07-15",
                        inputTokens: nil,
                        outputTokens: nil,
                        totalTokens: 10,
                        costUSD: cost,
                        modelsUsed: nil,
                        modelBreakdowns: nil),
                ],
                updatedAt: self.now))
    }

    private static func waitUntil(_ condition: @MainActor () -> Bool) async {
        // Loaded macOS CI can stall MainActor startup long enough for a seeded confirmed-empty
        // snapshot to age out; wait well past that boundary before treating publication as absent.
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if condition() {
                return
            }
            try? await Task.sleep(for: .milliseconds(2))
        }
        Issue.record("Timed out waiting for Spend Dashboard publication")
    }

    private static let now = Date(timeIntervalSince1970: 1_784_179_200)
    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private static func fixture() -> (request: SpendDashboardLoadRequest, result: SpendDashboardLoadResult) {
        let configuration = SpendDashboardConfiguration(
            costUsageEnabled: true,
            providerIDs: [
                UsageProvider.devin.rawValue,
                UsageProvider.deepseek.rawValue,
                UsageProvider.claude.rawValue,
                UsageProvider.opencode.rawValue,
            ])
        let deepseek = Self.input(id: "deepseek", provider: .deepseek, cost: 7)
        return (
            request: SpendDashboardLoadRequest(
                configuration: configuration,
                capturedInputs: [deepseek],
                unavailableSourceIDs: ["opencode"],
                confirmedEmptySourceIDs: ["claude"],
                now: Self.now,
                force: false),
            result: SpendDashboardLoadResult(
                inputs: [
                    deepseek,
                    Self.input(id: "devin:first", provider: .devin, cost: 2),
                    Self.input(id: "devin:second", provider: .devin, cost: 3),
                ],
                failedSourceIDs: ["opencode"]))
    }
}

private actor SpendDashboardPublicationScript {
    private var requests: [SpendDashboardLoadRequest]
    private var results: [SpendDashboardLoadResult]

    init(requests: [SpendDashboardLoadRequest], results: [SpendDashboardLoadResult]) {
        self.requests = requests
        self.results = results
    }

    func nextRequest(mode: SpendDashboardRequestBuildMode) -> SpendDashboardLoadRequest {
        precondition(!self.requests.isEmpty, "Unexpected Spend Dashboard publication request")
        let request = self.requests.removeFirst()
        return SpendDashboardLoadRequest(
            configuration: request.configuration,
            capturedInputs: request.capturedInputs,
            unavailableSourceIDs: request.unavailableSourceIDs,
            confirmedEmptySourceIDs: request.confirmedEmptySourceIDs,
            now: request.now,
            force: mode.forcesLoader)
    }

    func nextResult(request: SpendDashboardLoadRequest) -> SpendDashboardLoadResult {
        guard !self.results.isEmpty else {
            Issue.record("Unexpected Spend Dashboard publication load for \(request.configuration.providerIDs)")
            return SpendDashboardLoadResult(inputs: [], failedSourceIDs: [])
        }
        return self.results.removeFirst()
    }
}

private actor SpendDashboardPublicationLoadCounter {
    private(set) var count = 0

    func recordLoad() {
        self.count += 1
    }
}
