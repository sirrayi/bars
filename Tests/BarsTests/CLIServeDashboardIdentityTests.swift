import Commander
import Foundation
import Testing
@testable import BarsCLI
@testable import BarsCore

/// `bars serve` resolves dashboard identity per request: an explicit `--identity` pins the
/// mode, and an absent flag follows the app's "Hide personal information" setting. The resolved
/// mode also joins the cache key so a body cached before a toggle cannot be replayed after it.
struct CLIServeDashboardIdentityTests {
    @Test
    func `returning to an expired fill mode rebuilds the dashboard before responding`() async throws {
        let store = testConfigStore(suiteName: "CLIServeDashboardIdentityTests-\(UUID().uuidString)")
        defer { try? store.deleteIfPresent() }
        let config = BarsConfig(providers: UsageProvider.allCases.map {
            ProviderConfig(id: $0.instanceID, enabled: false)
        })
        try store.save(config)
        let (clock, cache) = makeServeTestCache()
        let showUsed = BarsCLI.usageBarsShowUsedFromDefaults()
        let token = try BarsCLI.serveConfigCacheToken(for: config)
        // The requested mode was last collected five minutes ago; the opposite mode is fresh.
        for mode in [showUsed, !showUsed] {
            let key = try BarsCLI.serveDashboardOperationKey(
                identityMode: .redacted, usageBarsShowUsed: mode, provider: nil)
            _ = await BarsCLI.cachedServeResponse(
                key: key, cache: cache, refreshInterval: 60, configFingerprint: token)
            {
                CLILocalHTTPResponse(status: .ok, body: Data("old-mode-snapshot".utf8))
            }
            if mode == showUsed { clock.advance(by: 300) }
        }
        let runtime = ServeRuntime(
            configStore: store,
            cache: cache,
            providerOperations: CLIServeOperationCoordinator(),
            costOperations: CLIServeOperationCoordinator(),
            refreshInterval: 60,
            requestTimeout: 5,
            healthVersion: "0.0.0-test",
            dashboardAuth: CLIServeDashboardAuth(bearer: "fixture-token"),
            dashboardIdentityMode: .redacted,
            bindHost: "127.0.0.1")
        let response = await BarsCLI.handleServeRequest(CLILocalHTTPRequest(
            method: "GET",
            target: "/dashboard/v1/snapshot",
            host: "localhost",
            path: "/dashboard/v1/snapshot",
            queryItems: [:],
            authorization: "Bearer fixture-token"), runtime: runtime)
        #expect(response.status == .ok)
        #expect(response.body != Data("old-mode-snapshot".utf8))
        await cache.operations.shutdown()
        await runtime.providerOperations.shutdown()
        await runtime.costOperations.shutdown()
    }

    @Test
    func `dashboard identity follows the app privacy setting without a flag`() {
        #expect(BarsCLI.resolveDashboardIdentityMode(
            configured: nil,
            hidesPersonalInfo: true) == .redacted)
        #expect(BarsCLI.resolveDashboardIdentityMode(
            configured: nil,
            hidesPersonalInfo: false) == .full)
    }

    @Test
    func `dashboard identity flag overrides the app privacy setting`() {
        #expect(BarsCLI.resolveDashboardIdentityMode(
            configured: .full,
            hidesPersonalInfo: true) == .full)
        #expect(BarsCLI.resolveDashboardIdentityMode(
            configured: .redacted,
            hidesPersonalInfo: false) == .redacted)
    }

    @Test
    func `dashboard identity flag presence separates an explicit full from an absent flag`() {
        #expect(BarsCLI.dashboardIdentityFlagPresent(in: ParsedValues(
            positional: [],
            options: ["identity": ["full"]],
            flags: [])))
        #expect(!BarsCLI.dashboardIdentityFlagPresent(in: ParsedValues(
            positional: [],
            options: [:],
            flags: [])))
    }

    @Test
    func `an absent identity flag still decodes to the full default`() {
        #expect(BarsCLI.decodeDashboardIdentityMode(from: ParsedValues(
            positional: [],
            options: [:],
            flags: [])) == .full)
    }

    @Test
    func `dashboard operation key separates identity modes`() throws {
        let redacted = try BarsCLI.serveDashboardOperationKey(
            identityMode: .redacted,
            usageBarsShowUsed: false,
            provider: nil)
        let full = try BarsCLI.serveDashboardOperationKey(
            identityMode: .full,
            usageBarsShowUsed: false,
            provider: nil)

        #expect(redacted != full)
    }

    @Test
    func `dashboard operation key separates usage bars fill preferences`() throws {
        let used = try BarsCLI.serveDashboardOperationKey(
            identityMode: .full,
            usageBarsShowUsed: true,
            provider: nil)
        let remaining = try BarsCLI.serveDashboardOperationKey(
            identityMode: .full,
            usageBarsShowUsed: false,
            provider: nil)

        #expect(used != remaining)
    }

    @Test
    func `warm dashboard responses retain the requested fill mode through toggles`() async throws {
        let (_, cache) = makeServeTestCache()
        let counter = DashboardFillBuildCounter()
        for showUsed in [false, true, false, true] {
            let key = try BarsCLI.serveDashboardOperationKey(
                identityMode: .redacted,
                usageBarsShowUsed: showUsed,
                provider: "opencode")
            let response = await BarsCLI.cachedServeResponse(
                key: key, cache: cache, refreshInterval: 60, configFingerprint: "synthetic-config")
            {
                let build = await counter.increment()
                return CLILocalHTTPResponse(
                    status: .ok,
                    body: Data("{\"usageBarsShowUsed\":\(showUsed),\"build\":\(build)}".utf8))
            }
            let payload = try #require(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
            #expect(payload["usageBarsShowUsed"] as? Bool == showUsed)
        }
        #expect(await counter.count == 2)
    }
}

private actor DashboardFillBuildCounter {
    private(set) var count = 0

    func increment() -> Int {
        self.count += 1
        return self.count
    }
}
