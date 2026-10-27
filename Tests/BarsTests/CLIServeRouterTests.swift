import Commander
import Foundation
import Testing
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
@testable import BarsCLI
@testable import BarsCore

// Cache state-machine coverage is intentionally kept together for sequence readability.
// swiftlint:disable:next type_body_length
struct CLIServeRouterTests {
    @Test
    func `local HTTP connection gate caps pre-auth clients`() {
        let gate = CLILocalHTTPConnectionGate(maximumConnections: 2)

        #expect(gate.tryAcquire())
        #expect(gate.tryAcquire())
        #expect(!gate.tryAcquire())
        #expect(gate.activeCount == 2)
        gate.release()
        #expect(gate.tryAcquire())
        #expect(gate.activeCount == 2)
        gate.release()
        gate.release()
        #expect(gate.activeCount == 0)
    }

    @Test
    func `usage operation fingerprint separates all account mode`() {
        let allAccounts = BarsCLI.serveUsageOperationFingerprint(
            configFingerprint: "config",
            includeAllAccounts: true)
        let selectedAccount = BarsCLI.serveUsageOperationFingerprint(
            configFingerprint: "config",
            includeAllAccounts: false)

        #expect(allAccounts != selectedAccount)
        #expect(allAccounts == BarsCLI.serveUsageOperationFingerprint(
            configFingerprint: "config",
            includeAllAccounts: true))
    }

    @Test
    func `termination monitor handles interactive and hangup signals`() {
        #expect(CLITerminationSignalMonitor.signalNumbers == [SIGINT, SIGTERM, SIGHUP])
    }

    @Test
    func `local http parser accepts only loopback host headers`() throws {
        let allowedHosts = [
            "localhost",
            "localhost.",
            "localhost:8080",
            "127.0.0.1",
            "127.0.0.1:8080",
            "[::1]",
            "[::1]:8080",
        ]

        for host in allowedHosts {
            let request = try Self.parsedRequest(host: host)
            #expect(request.host == host)
            #expect(request.path == "/usage")
        }
    }

    @Test
    func `local http parser rejects hostile missing and duplicate hosts`() {
        Self.expectParseFailure(raw: "GET /usage HTTP/1.1\r\n\r\n", .missingHost)
        Self.expectParseFailure(raw: "GET /usage HTTP/1.1\r\nHost: evil.test\r\n\r\n", .disallowedHost)
        Self.expectParseFailure(raw: "GET /usage HTTP/1.1\r\nHost: localhost, evil.test\r\n\r\n", .disallowedHost)
        Self.expectParseFailure(raw: "GET /usage HTTP/1.1\r\nHost: localhost:abc\r\n\r\n", .disallowedHost)
        Self.expectParseFailure(
            raw: "GET /usage HTTP/1.1\r\nHost: localhost\r\nHost: 127.0.0.1\r\n\r\n",
            .duplicateHost)
    }

    @Test
    func `local http parser captures a single authorization header`() throws {
        let raw = [
            "GET /usage HTTP/1.1",
            "Host: localhost",
            "authorization: Bearer token",
            "",
            "",
        ].joined(separator: "\r\n")
        let request = try CLILocalHTTPRequest.parse(Data(raw.utf8)).get()

        #expect(request.authorization == "Bearer token")
        #expect(try Self.parsedRequest(host: "localhost").authorization == nil)
        Self.expectParseFailure(
            raw: "GET /usage HTTP/1.1\r\nHost: localhost\r\nAuthorization: a\r\nAuthorization: b\r\n\r\n",
            .duplicateAuthorization)
    }

    @Test
    func `local http parser extends the allowed host set without replacing loopback`() throws {
        let raw = "GET /usage HTTP/1.1\r\nHost: 192.168.1.10:8080\r\n\r\n"

        Self.expectParseFailure(raw: raw, .disallowedHost)

        let allowed = CLILocalHTTPAllowedHosts.loopbackAnd(["192.168.1.10"])
        let request = try CLILocalHTTPRequest.parse(Data(raw.utf8), allowedHosts: allowed).get()
        #expect(request.host == "192.168.1.10:8080")
        #expect(request.path == "/usage")
        let loopback = try CLILocalHTTPRequest.parse(
            Data("GET /usage HTTP/1.1\r\nHost: localhost\r\n\r\n".utf8),
            allowedHosts: allowed).get()
        #expect(loopback.host == "localhost")
        Self.expectParseFailure(
            raw: "GET /usage HTTP/1.1\r\nHost: evil.test\r\n\r\n",
            .disallowedHost,
            allowedHosts: allowed)

        let wildcard = try CLILocalHTTPRequest.parse(Data(raw.utf8), allowedHosts: .any).get()
        #expect(wildcard.host == "192.168.1.10:8080")
        let alternateLoopback = try CLILocalHTTPRequest.parse(
            Data("GET /usage HTTP/1.1\r\nHost: 127.0.0.2\r\n\r\n".utf8),
            allowedHosts: CLIServeSecurity.allowedHosts(forBindHost: "127.0.0.2")).get()
        #expect(alternateLoopback.host == "127.0.0.2")
        Self.expectParseFailure(
            raw: "GET /usage HTTP/1.1\r\nHost: 192.168.1.10, evil.test\r\n\r\n",
            .disallowedHost,
            allowedHosts: .any)
    }

    @Test
    func `routes web UI health usage cost and dashboard endpoints`() throws {
        #expect(try CLIServeRouter.route(method: "GET", path: "/", queryItems: [:]) == .webUI)
        #expect(try CLIServeRouter.route(method: "GET", path: "/health", queryItems: [:]) == .health)
        #expect(try CLIServeRouter.route(method: "GET", path: "/accounts", queryItems: [:]) == .accounts(id: nil))
        #expect(
            try CLIServeRouter.route(
                method: "GET",
                path: "/accounts/token-account:claude:aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
                queryItems: [:]) ==
                .accounts(id: "token-account:claude:aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"))
        #expect(try CLIServeRouter.route(method: "GET", path: "/usage", queryItems: [:]) == .usage(provider: nil))
        #expect(
            try CLIServeRouter.route(
                method: "GET",
                path: "/usage",
                queryItems: ["provider": "claude"]) == .usage(provider: "claude"))
        #expect(
            try CLIServeRouter.route(
                method: "GET",
                path: "/cost",
                queryItems: ["provider": "opencode"]) == .cost(provider: "opencode"))
        #expect(
            try CLIServeRouter.route(
                method: "GET",
                path: "/dashboard/v1/snapshot",
                queryItems: [:]) == .dashboardSnapshot(provider: nil, detail: nil))
        #expect(
            try CLIServeRouter.route(
                method: "GET",
                path: "/dashboard/v1/snapshot",
                queryItems: ["provider": "claude"]) == .dashboardSnapshot(provider: "claude", detail: nil))
        #expect(
            try CLIServeRouter.route(
                method: "GET",
                path: "/dashboard/v1/snapshot",
                queryItems: ["detail": "shell"]) == .dashboardSnapshot(provider: nil, detail: "shell"))
        #expect(
            try CLIServeRouter.route(
                method: "GET",
                path: "/dashboard/v1/snapshot",
                queryItems: ["detail": "full"]) == .dashboardSnapshot(provider: nil, detail: "full"))
        #expect(
            try CLIServeRouter.route(
                method: "GET",
                path: "/dashboard/v1/snapshot",
                queryItems: ["provider": "opencode", "detail": "shell"]) ==
                .dashboardSnapshot(provider: "opencode", detail: "shell"))
    }

    @Test
    func `rejects non get methods`() {
        do {
            _ = try CLIServeRouter.route(method: "POST", path: "/usage", queryItems: [:])
            Issue.record("Expected methodNotAllowed")
        } catch let error as CLIServeRouteError {
            #expect(error == .methodNotAllowed)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func `rejects post to web UI`() {
        do {
            _ = try CLIServeRouter.route(method: "POST", path: "/", queryItems: [:])
            Issue.record("Expected methodNotAllowed")
        } catch let error as CLIServeRouteError {
            #expect(error == .methodNotAllowed)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func `rejects unknown paths`() {
        do {
            _ = try CLIServeRouter.route(method: "GET", path: "/missing", queryItems: [:])
            Issue.record("Expected notFound")
        } catch let error as CLIServeRouteError {
            #expect(error == .notFound)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func `health response reports ok status and build version`() throws {
        let response = BarsCLI.serveHealthResponse(version: "1.2.3")
        #expect(response.status == .ok)
        let object = try JSONSerialization.jsonObject(with: response.body) as? [String: Any]
        #expect(object?["status"] as? String == "ok")
        #expect(object?["version"] as? String == "1.2.3")
    }

    @Test
    func `health response omits version detail when unavailable`() throws {
        let response = BarsCLI.serveHealthResponse(version: nil)
        #expect(response.status == .ok)
        let object = try JSONSerialization.jsonObject(with: response.body) as? [String: Any]
        #expect(object?["status"] as? String == "ok")
        #expect(object?.keys.contains("version") == false)
    }

    @Test
    func `serve numeric options reject malformed values`() {
        #expect(BarsCLI.decodeServePort(from: ParsedValues(
            positional: [],
            options: ["port": ["abc"]],
            flags: [])) == nil)
        #expect(BarsCLI.decodeServePort(from: ParsedValues(
            positional: [],
            options: ["port": ["0"]],
            flags: [])) == nil)
        #expect(BarsCLI.decodeServePort(from: ParsedValues(
            positional: [],
            options: ["port": ["65536"]],
            flags: [])) == nil)
        #expect(BarsCLI.decodeServePort(from: ParsedValues(
            positional: [],
            options: [:],
            flags: [])) == 8080)

        #expect(BarsCLI.decodeServeRefreshInterval(from: ParsedValues(
            positional: [],
            options: ["refreshInterval": ["later"]],
            flags: [])) == nil)
        #expect(BarsCLI.decodeServeRefreshInterval(from: ParsedValues(
            positional: [],
            options: ["refreshInterval": ["-1"]],
            flags: [])) == nil)
        #expect(BarsCLI.decodeServeRefreshInterval(from: ParsedValues(
            positional: [],
            options: ["refreshInterval": ["inf"]],
            flags: [])) == nil)
        #expect(BarsCLI.decodeServeRefreshInterval(from: ParsedValues(
            positional: [],
            options: ["refreshInterval": ["86401"]],
            flags: [])) == 86401)
        #expect(BarsCLI.decodeServeRefreshInterval(from: ParsedValues(
            positional: [],
            options: ["refreshInterval": ["86400"]],
            flags: [])) == 86400)
        #expect(BarsCLI.decodeServeRefreshInterval(from: ParsedValues(
            positional: [],
            options: [:],
            flags: [])) == 60)

        #expect(BarsCLI.decodeServeRequestTimeout(from: ParsedValues(
            positional: [],
            options: ["requestTimeout": ["soon"]],
            flags: [])) == nil)
        #expect(BarsCLI.decodeServeRequestTimeout(from: ParsedValues(
            positional: [],
            options: ["requestTimeout": ["-0.5"]],
            flags: [])) == nil)
        #expect(BarsCLI.decodeServeRequestTimeout(from: ParsedValues(
            positional: [],
            options: ["requestTimeout": ["inf"]],
            flags: [])) == nil)
        #expect(BarsCLI.decodeServeRequestTimeout(from: ParsedValues(
            positional: [],
            options: ["requestTimeout": ["0"]],
            flags: [])) == 0)
        #expect(BarsCLI.decodeServeRequestTimeout(from: ParsedValues(
            positional: [],
            options: ["requestTimeout": ["12.5"]],
            flags: [])) == 12.5)
        #expect(BarsCLI.decodeServeRequestTimeout(from: ParsedValues(
            positional: [],
            options: [:],
            flags: [])) == 30)
    }

    @Test
    func `serve help documents request timeout option`() {
        let serve = BarsCLI.serveHelp(version: "0.0.0")
        let root = BarsCLI.rootHelp(version: "0.0.0")

        #expect(serve.contains("--request-timeout <seconds>"))
        #expect(serve.contains("bars serve --port 8080 --refresh-interval 60 --request-timeout 30"))
        #expect(serve.contains("GET /accounts"))
        #expect(serve.contains("GET /accounts/<id>"))
        #expect(serve.contains("Account IDs are stable opaque identifiers"))
        #expect(serve.contains("never returns credentials or refreshes usage"))
        #expect(root.contains("--request-timeout <seconds>"))
    }

    @Test
    func `serve config snapshot reflects provider changes`() throws {
        let store = testConfigStore(suiteName: "CLIServeRouterTests-serve-config-freshness-\(UUID().uuidString)")
        defer { try? store.deleteIfPresent() }
        var firstConfig = BarsConfig.makeDefault()
        firstConfig.setProviderConfig(ProviderConfig(id: .opencodego, enabled: false))
        try store.save(firstConfig)

        let firstSnapshot = try BarsCLI.loadServeConfigSnapshot(configStore: store)

        var secondConfig = firstConfig
        secondConfig.setProviderConfig(ProviderConfig(id: .opencodego, enabled: true))
        try store.save(secondConfig)
        let secondSnapshot = try BarsCLI.loadServeConfigSnapshot(configStore: store)

        #expect(!firstSnapshot.config.enabledProviders().contains(.opencodego))
        #expect(secondSnapshot.config.enabledProviders().contains(.opencodego))
        #expect(firstSnapshot.cacheToken != secondSnapshot.cacheToken)
        let operationKey = try BarsCLI.serveOperationKey(kind: "usage", provider: nil)
        #expect(try operationKey == (BarsCLI.serveOperationKey(kind: "usage", provider: nil)))
        #expect(
            BarsCLI.serveCacheKey(operationKey: operationKey, configToken: firstSnapshot.cacheToken) !=
                BarsCLI.serveCacheKey(operationKey: operationKey, configToken: secondSnapshot.cacheToken))
    }

    @Test
    func `serve cache skips provider error payloads`() {
        let success = CLILocalHTTPResponse(
            status: .ok,
            body: Data(#"[{"provider":"opencode","source":"local"}]"#.utf8))
        let providerError = CLILocalHTTPResponse(
            status: .ok,
            body: Data(#"[{"provider":"opencode","source":"local","error":{"message":"temporary"}}]"#.utf8))
        let routeError = CLILocalHTTPResponse(
            status: .badRequest,
            body: Data(#"{"error":"bad request"}"#.utf8))

        #expect(BarsCLI.shouldCacheServeResponse(success))
        #expect(!BarsCLI.shouldCacheServeResponse(providerError))
        #expect(!BarsCLI.shouldCacheServeResponse(routeError))
    }

    @Test
    func `serve provider timeout stays below the request deadline`() throws {
        let thirtySecondTimeout = try #require(BarsCLI.serveProviderTimeout(requestTimeout: 30))
        let tenSecondTimeout = try #require(BarsCLI.serveProviderTimeout(requestTimeout: 10))
        #expect(abs(thirtySecondTimeout - 24) < 1e-9)
        #expect(abs(tenSecondTimeout - 8) < 1e-9)
        // Outer deadline disabled (0) or non-finite: add no serve-level provider bound.
        #expect(BarsCLI.serveProviderTimeout(requestTimeout: 0) == nil)
        #expect(BarsCLI.serveProviderTimeout(requestTimeout: .infinity) == nil)
        // Finite deadlines stay strictly below the request timeout at every
        // value, including sub-second ones.
        let oneSecondTimeout = try #require(BarsCLI.serveProviderTimeout(requestTimeout: 1))
        let halfSecondTimeout = try #require(BarsCLI.serveProviderTimeout(requestTimeout: 0.5))
        #expect(oneSecondTimeout < 1)
        #expect(abs(halfSecondTimeout - 0.4) < 1e-9)
        // Oversized finite deadlines share the outer 24-hour cap and cannot
        // overflow Duration conversion.
        let oversizedTimeout = try #require(BarsCLI.serveProviderTimeout(
            requestTimeout: .greatestFiniteMagnitude))
        #expect(abs(oversizedTimeout - 69120) < 1e-9)
        #expect(oversizedTimeout < 86400)
    }

    @Test
    func `serve usage collection adds no join bound when request deadline is disabled`() async {
        let output = await BarsCLI.serveCollectUsageOutputs(
            providers: [.opencode, .claude],
            providerTimeout: nil)
        { provider in
            if provider == .opencode {
                try? await Task.sleep(for: .milliseconds(25))
            }
            return UsageCommandOutput(sections: ["ok:\(provider.rawValue)"])
        }

        #expect(output.sections == ["ok:opencode", "ok:claude"])
        #expect(output.payload.isEmpty)
        #expect(output.exitCode == .success)
    }

    @Test
    func `serve cache coalesces concurrent cache misses`() async {
        let cache = CLIServeResponseCache()
        let counter = ServeTestCounter()

        let responses = await withTaskGroup(of: CLILocalHTTPResponse.self) { group -> [CLILocalHTTPResponse] in
            for _ in 0..<5 {
                group.addTask {
                    await BarsCLI.cachedServeResponse(
                        key: "usage:",
                        cache: cache,
                        refreshInterval: 60,
                        requestTimeout: 0)
                    {
                        let call = await counter.increment()
                        try? await Task.sleep(nanoseconds: 50_000_000)
                        return Self.response("[{\"provider\":\"opencode\",\"call\":\(call)}]")
                    }
                }
            }

            var responses: [CLILocalHTTPResponse] = []
            for await response in group {
                responses.append(response)
            }
            return responses
        }

        #expect(await counter.current() == 1)
        #expect(Set(responses.map(Self.bodyString)).count == 1)
        #expect(responses.allSatisfy { $0.status == .ok })
        #expect(responses.allSatisfy { Self.bodyString($0).contains("\"call\":1") })
    }

    @Test
    func `serve cache prunes expired config token entries`() async {
        let (wallClock, cache) = makeServeTestCache()

        _ = await BarsCLI.cachedServeResponse(
            key: "usage::old-config",
            cache: cache,
            refreshInterval: 0.001)
        {
            Self.response(#"[{"provider":"opencode","config":"old"}]"#)
        }
        #expect(await cache.cachedEntryCount() == 1)

        wallClock.advance(by: 0.001)
        _ = await BarsCLI.cachedServeResponse(
            key: "usage::new-config",
            cache: cache,
            refreshInterval: 60)
        {
            Self.response(#"[{"provider":"opencode","config":"new"}]"#)
        }

        #expect(await cache.cachedEntryCount() == 1)
    }

    @Test
    func `serve cache does not cache timeout responses and recovers on next success`() async {
        let cache = CLIServeResponseCache()
        let counter = ServeTestCounter()

        let timeout = await BarsCLI.cachedServeResponse(
            key: "usage:",
            cache: cache,
            refreshInterval: 60,
            requestTimeout: 0)
        {
            _ = await counter.increment()
            return BarsCLI.serveTimeoutResponse()
        }

        #expect(timeout.status == .gatewayTimeout)
        #expect(Self.bodyString(timeout).contains("request timed out"))

        let success = await BarsCLI.cachedServeResponse(
            key: "usage:",
            cache: cache,
            refreshInterval: 60,
            requestTimeout: 0)
        {
            let call = await counter.increment()
            return Self.response("[{\"provider\":\"opencode\",\"call\":\(call)}]")
        }

        #expect(success.status == .ok)
        #expect(Self.bodyString(success).contains("\"call\":2"))

        let cached = await BarsCLI.cachedServeResponse(
            key: "usage:",
            cache: cache,
            refreshInterval: 60,
            requestTimeout: 0)
        {
            let call = await counter.increment()
            return Self.response("[{\"provider\":\"opencode\",\"call\":\(call)}]")
        }

        #expect(cached.status == .ok)
        #expect(Self.bodyString(cached) == Self.bodyString(success))
        #expect(await counter.current() == 2)
    }

    @Test
    func `serve cache resumes coalesced waiters on timeout`() async {
        let cache = CLIServeResponseCache()
        let counter = ServeTestCounter()

        let responses = await withTaskGroup(of: CLILocalHTTPResponse.self) { group -> [CLILocalHTTPResponse] in
            for _ in 0..<4 {
                group.addTask {
                    await BarsCLI.cachedServeResponse(
                        key: "usage:",
                        cache: cache,
                        refreshInterval: 60,
                        requestTimeout: 0.01)
                    {
                        _ = await counter.increment()
                        await Self.hangPastRequestDeadline()
                        return Self.response("[{\"provider\":\"opencode\"}]")
                    }
                }
            }

            var responses: [CLILocalHTTPResponse] = []
            for await response in group {
                responses.append(response)
            }
            return responses
        }

        #expect(await counter.current() == 1)
        #expect(responses.count == 4)
        #expect(responses.allSatisfy { $0.status == .gatewayTimeout })
        #expect(responses.allSatisfy { Self.bodyString($0).contains("request timed out") })
    }

    @Test
    func `serve cache serves last good payload when refresh fails`() async {
        let (wallClock, cache) = makeServeTestCache()
        let counter = ServeTestCounter()

        let first = await BarsCLI.cachedServeResponse(
            key: "usage:antigravity",
            cache: cache,
            refreshInterval: 0.05,
            requestTimeout: 1)
        {
            let call = await counter.increment()
            return Self.response("[{\"provider\":\"antigravity\",\"call\":\(call)}]")
        }
        #expect(first.status == .ok)

        wallClock.advance(by: 0.05)

        let failed = await BarsCLI.cachedServeResponse(
            key: "usage:antigravity",
            cache: cache,
            refreshInterval: 0.05,
            requestTimeout: 1)
        {
            _ = await counter.increment()
            return Self.response(
                "[{\"provider\":\"antigravity\",\"error\":{\"message\":\"transient\"}}]")
        }

        // Transient failure is masked by the last good payload.
        #expect(failed.status == .ok)
        let failedRows = try? Self.jsonRows(failed)
        #expect(failedRows?.first?["call"] as? Int == 1)
        #expect(await counter.current() == 2)

        wallClock.advance(by: 0.05)

        let recovered = await BarsCLI.cachedServeResponse(
            key: "usage:antigravity",
            cache: cache,
            refreshInterval: 0.05,
            requestTimeout: 1)
        {
            let call = await counter.increment()
            return Self.response("[{\"provider\":\"antigravity\",\"call\":\(call)}]")
        }

        #expect(recovered.status == .ok)
        #expect(Self.bodyString(recovered).contains("\"call\":3"))
    }

    @Test
    func `cost refresh timeout serves the last good payload`() async throws {
        let wallClock = ServeTestWallClock()
        let deadline = ServeListeningSignal()
        let releaseSource = ServeListeningSignal()
        defer { releaseSource.signal() }
        let operations = CLIServeOperationCoordinator<CLIServeCoordinatedResponse>(
            sleepUntil: { _ in await deadline.wait() })
        let cache = CLIServeResponseCache(operations: operations, wallClock: wallClock.now)
        let counter = ServeTestCounter()

        let first = await BarsCLI.cachedServeResponse(
            key: "cost:",
            cache: cache,
            refreshInterval: 0.01,
            requestTimeout: 0)
        {
            let call = await counter.increment()
            return Self.response("[{\"provider\":\"opencode\",\"call\":\(call)}]")
        }
        wallClock.advance(by: 0.01)

        let sourceEntered = ServeListeningSignal()
        let request = Task {
            await BarsCLI.cachedServeResponse(
                key: "cost:",
                cache: cache,
                refreshInterval: 0.01,
                requestTimeout: 30)
            {
                let call = await counter.increment()
                sourceEntered.signal()
                await releaseSource.wait()
                return Self.response("[{\"provider\":\"opencode\",\"call\":\(call)}]")
            }
        }
        await sourceEntered.wait()
        deadline.signal()
        let timedOut = await request.value

        #expect(timedOut.status == .ok)
        let firstRows = try Self.jsonRows(first)
        let timedOutRows = try Self.jsonRows(timedOut)
        #expect(firstRows.first?["provider"] as? String == "opencode")
        #expect(timedOutRows.first?["provider"] as? String == "opencode")
        #expect(firstRows.first?["call"] as? Int == 1)
        #expect(timedOutRows.first?["call"] as? Int == 1)
        #expect(await counter.current() == 2)

        releaseSource.signal()
        for _ in 0..<1000 where await operations.snapshot().operationCount != 0 {
            await Task.yield()
        }
        #expect(await operations.snapshot().operationCount == 0)
    }

    @Test
    func `cost refresh keeps fresh providers while replacing timed out rows`() async throws {
        let (wallClock, cache) = makeServeTestCache()

        _ = await BarsCLI.cachedServeResponse(
            key: "cost:",
            cache: cache,
            refreshInterval: 0.01,
            requestTimeout: 1)
        {
            Self.response("""
            [
              {"provider":"opencode","call":1},
              {"provider":"claude","call":1}
            ]
            """)
        }
        wallClock.advance(by: 0.01)

        let partial = await BarsCLI.cachedServeResponse(
            key: "cost:",
            cache: cache,
            refreshInterval: 0.01,
            requestTimeout: 1)
        {
            Self.response("""
            [
              {"provider":"opencode","call":2},
              {"provider":"claude","error":{"message":"claude cost refresh timed out"}}
            ]
            """)
        }
        let partialRows = try Self.jsonRows(partial)
        #expect(Self.row(partialRows, provider: "opencode")?["call"] as? Int == 2)
        #expect(Self.row(partialRows, provider: "claude")?["call"] as? Int == 1)
        #expect(partialRows.allSatisfy { $0["error"] == nil })

        wallClock.advance(by: 0.01)
        let timedOut = await BarsCLI.cachedServeResponse(
            key: "cost:",
            cache: cache,
            refreshInterval: 0.01,
            requestTimeout: 0.01)
        {
            await Self.hangPastRequestDeadline()
            return Self.response(#"[{"provider":"opencode","call":3}]"#)
        }
        let timeoutRows = try Self.jsonRows(timedOut)
        #expect(Self.row(timeoutRows, provider: "opencode")?["call"] as? Int == 2)
        #expect(Self.row(timeoutRows, provider: "claude")?["call"] as? Int == 1)
    }

    @Test
    func `serve cache replaces only failed provider account rows`() async throws {
        let (wallClock, cache) = makeServeTestCache()

        _ = await BarsCLI.cachedServeResponse(
            key: "usage:",
            cache: cache,
            refreshInterval: 0.05,
            requestTimeout: 1)
        {
            Self.response("""
            [
              {"provider":"opencode","account":"personal","call":1},
              {"provider":"antigravity","account":"work","call":1},
              {"provider":"antigravity","account":"personal","call":1}
            ]
            """)
        }

        wallClock.advance(by: 0.05)

        let refreshed = await BarsCLI.cachedServeResponse(
            key: "usage:",
            cache: cache,
            refreshInterval: 0.05,
            requestTimeout: 1)
        {
            Self.response("""
            [
              {"provider":"opencode","account":"personal","call":2},
              {"provider":"antigravity","account":"work","error":{"message":"transient"}},
              {"provider":"antigravity","account":"personal","call":2}
            ]
            """)
        }
        let rows = try Self.jsonRows(refreshed)

        #expect(Self.row(rows, provider: "opencode", account: "personal")?["call"] as? Int == 2)
        #expect(Self.row(rows, provider: "antigravity", account: "work")?["call"] as? Int == 1)
        #expect(Self.row(rows, provider: "antigravity", account: "personal")?["call"] as? Int == 2)
        #expect(rows.allSatisfy { $0["error"] == nil })
    }

    @Test
    func `serve cache retains newer per-row success across all-error refresh`() async throws {
        let (wallClock, cache) = makeServeTestCache()

        _ = await BarsCLI.cachedServeResponse(
            key: "usage:",
            cache: cache,
            refreshInterval: 0.05,
            requestTimeout: 1)
        {
            Self.response("""
            [
              {"provider":"opencode","call":1},
              {"provider":"antigravity","call":1}
            ]
            """)
        }
        wallClock.advance(by: 0.05)

        _ = await BarsCLI.cachedServeResponse(
            key: "usage:",
            cache: cache,
            refreshInterval: 0.05,
            requestTimeout: 1)
        {
            Self.response("""
            [
              {"provider":"opencode","call":2},
              {"provider":"antigravity","error":{"message":"transient"}}
            ]
            """)
        }
        wallClock.advance(by: 0.05)

        let failed = await BarsCLI.cachedServeResponse(
            key: "usage:",
            cache: cache,
            refreshInterval: 0.05,
            requestTimeout: 1)
        {
            Self.response("""
            [
              {"provider":"opencode","error":{"message":"transient"}},
              {"provider":"antigravity","error":{"message":"transient"}}
            ]
            """)
        }
        let rows = try Self.jsonRows(failed)

        #expect(Self.row(rows, provider: "opencode")?["call"] as? Int == 2)
        #expect(Self.row(rows, provider: "antigravity")?["call"] as? Int == 1)
    }

    @Test
    func `serve cache fails closed on timeout after merged rows`() async {
        let (wallClock, cache) = makeServeTestCache()

        _ = await BarsCLI.cachedServeResponse(
            key: "usage:",
            cache: cache,
            refreshInterval: 0.05,
            requestTimeout: 1)
        {
            Self.response("""
            [
              {"provider":"opencode","call":1},
              {"provider":"antigravity","call":1}
            ]
            """)
        }
        wallClock.advance(by: 0.05)

        _ = await BarsCLI.cachedServeResponse(
            key: "usage:",
            cache: cache,
            refreshInterval: 0.05,
            requestTimeout: 1)
        {
            Self.response("""
            [
              {"provider":"opencode","call":2},
              {"provider":"antigravity","error":{"message":"transient"}}
            ]
            """)
        }
        wallClock.advance(by: 0.05)

        let timedOut = await BarsCLI.cachedServeResponse(
            key: "usage:",
            cache: cache,
            refreshInterval: 0.05,
            requestTimeout: 0.01)
        {
            await Self.hangPastRequestDeadline()
            return Self.response("[]")
        }
        #expect(timedOut.status == .gatewayTimeout)
        #expect(!Self.bodyString(timedOut).contains("\"call\":1"))
        #expect(!Self.bodyString(timedOut).contains("\"call\":2"))
    }

    @Test
    func `serve cache fails closed on timeout after a partial refresh`() async {
        let (wallClock, cache) = makeServeTestCache()

        _ = await BarsCLI.cachedServeResponse(
            key: "usage:",
            cache: cache,
            refreshInterval: 0.05,
            requestTimeout: 1)
        {
            Self.response(#"[{"provider":"opencode","call":1}]"#)
        }
        wallClock.advance(by: 0.05)

        _ = await BarsCLI.cachedServeResponse(
            key: "usage:",
            cache: cache,
            refreshInterval: 0.05,
            requestTimeout: 1)
        {
            Self.response("""
            [
              {"provider":"opencode","call":2},
              {"provider":"antigravity","error":{"message":"transient"}}
            ]
            """)
        }
        wallClock.advance(by: 0.05)

        let timedOut = await BarsCLI.cachedServeResponse(
            key: "usage:",
            cache: cache,
            refreshInterval: 0.05,
            requestTimeout: 0.01)
        {
            await Self.hangPastRequestDeadline()
            return Self.response("[]")
        }
        #expect(timedOut.status == .gatewayTimeout)
        #expect(!Self.bodyString(timedOut).contains("\"call\":2"))
        #expect(!Self.bodyString(timedOut).contains("antigravity"))
    }

    @Test
    func `serve cache does not reconstruct usage rows after timeout`() async {
        let cache = CLIServeResponseCache()
        let policy = CLIServeResponseCache.CachePolicy(ttl: 0, staleTTL: 10)
        let startedAt = Date(timeIntervalSince1970: 1000)

        _ = await cache.completeFetch(
            Self.response(
                """
                [
                  {"provider":"opencode","call":1},
                  {"provider":"antigravity","call":1}
                ]
                """),
            for: "usage:",
            policy: policy,
            now: startedAt,
            shouldCache: true)

        let partialAt = startedAt.addingTimeInterval(9)
        _ = await cache.completeFetch(
            Self.response("""
            [
              {"provider":"opencode","call":2},
              {"provider":"antigravity","error":{"message":"transient"}}
            ]
            """),
            for: "usage:",
            policy: policy,
            now: partialAt,
            shouldCache: false)

        let timeoutAt = startedAt.addingTimeInterval(11)
        let timedOut = await cache.completeFetch(
            Self.response(#"{"error":"request timed out"}"#, status: .gatewayTimeout),
            for: "usage:",
            policy: policy,
            now: timeoutAt,
            shouldCache: false)
        #expect(timedOut.status == .gatewayTimeout)
        #expect(Self.bodyString(timedOut).contains("request timed out"))
        #expect(!Self.bodyString(timedOut).contains("\"call\":2"))
    }

    @Test
    func `serve cache preserves newer row when another failed row has no fallback`() async throws {
        let (wallClock, cache) = makeServeTestCache()

        _ = await BarsCLI.cachedServeResponse(
            key: "usage:",
            cache: cache,
            refreshInterval: 0.05,
            requestTimeout: 1)
        {
            Self.response(#"[{"provider":"opencode","call":1}]"#)
        }
        wallClock.advance(by: 0.05)

        _ = await BarsCLI.cachedServeResponse(
            key: "usage:",
            cache: cache,
            refreshInterval: 0.05,
            requestTimeout: 1)
        {
            Self.response("""
            [
              {"provider":"opencode","call":2},
              {"provider":"antigravity","error":{"message":"transient"}}
            ]
            """)
        }
        wallClock.advance(by: 0.05)

        let failed = await BarsCLI.cachedServeResponse(
            key: "usage:",
            cache: cache,
            refreshInterval: 0.05,
            requestTimeout: 1)
        {
            Self.response("""
            [
              {"provider":"opencode","error":{"message":"transient"}},
              {"provider":"antigravity","error":{"message":"transient"}}
            ]
            """)
        }
        let rows = try Self.jsonRows(failed)

        #expect(Self.row(rows, provider: "opencode")?["call"] as? Int == 2)
        #expect(Self.row(rows, provider: "antigravity")?["error"] != nil)
    }

    @Test
    func `serve cache keeps fresh rows when a failed row has no stale match`() async throws {
        let (wallClock, cache) = makeServeTestCache()

        _ = await BarsCLI.cachedServeResponse(
            key: "usage:",
            cache: cache,
            refreshInterval: 0.05,
            requestTimeout: 1)
        {
            Self.response(#"[{"provider":"opencode","account":"personal","call":1}]"#)
        }

        wallClock.advance(by: 0.05)

        let refreshed = await BarsCLI.cachedServeResponse(
            key: "usage:",
            cache: cache,
            refreshInterval: 0.05,
            requestTimeout: 1)
        {
            Self.response("""
            [
              {"provider":"opencode","account":"personal","call":2},
              {"provider":"antigravity","account":"work","error":{"message":"transient"}}
            ]
            """)
        }
        let rows = try Self.jsonRows(refreshed)

        #expect(Self.row(rows, provider: "opencode", account: "personal")?["call"] as? Int == 2)
        #expect(Self.row(rows, provider: "antigravity", account: "work")?["error"] != nil)
    }

    @Test
    func `serve cache does not merge duplicate provider account labels`() async throws {
        let (wallClock, cache) = makeServeTestCache()

        _ = await BarsCLI.cachedServeResponse(
            key: "usage:",
            cache: cache,
            refreshInterval: 0.05,
            requestTimeout: 1)
        {
            Self.response("""
            [
              {"provider":"opencode","account":"shared","slot":"first","call":1},
              {"provider":"opencode","account":"shared","slot":"second","call":1}
            ]
            """)
        }

        wallClock.advance(by: 0.05)

        let refreshed = await BarsCLI.cachedServeResponse(
            key: "usage:",
            cache: cache,
            refreshInterval: 0.05,
            requestTimeout: 1)
        {
            Self.response("""
            [
              {
                "provider":"opencode",
                "account":"shared",
                "slot":"first",
                "error":{"message":"transient"}
              },
              {"provider":"opencode","account":"shared","slot":"second","call":2}
            ]
            """)
        }
        let rows = try Self.jsonRows(refreshed)
        let first = rows.first { $0["slot"] as? String == "first" }
        let second = rows.first { $0["slot"] as? String == "second" }

        #expect(first?["error"] != nil)
        #expect(second?["call"] as? Int == 2)
    }

    @Test
    func `serve cache follows stable account identity across label changes`() async throws {
        let (wallClock, cache) = makeServeTestCache()

        _ = await BarsCLI.cachedServeResponse(
            key: "usage:",
            cache: cache,
            refreshInterval: 0.05,
            requestTimeout: 1)
        {
            Self.response(
                #"[{"provider":"opencode","account":"old label","call":1}]"#,
                usageCacheKeys: ["account-1"])
        }
        wallClock.advance(by: 0.05)

        let failed = await BarsCLI.cachedServeResponse(
            key: "usage:",
            cache: cache,
            refreshInterval: 0.05,
            requestTimeout: 1)
        {
            Self.response(
                #"[{"provider":"opencode","account":"new label","error":{"message":"transient"}}]"#,
                usageCacheKeys: ["account-1"])
        }
        let row = try #require(Self.jsonRows(failed).first)

        #expect(row["account"] as? String == "old label")
        #expect(row["call"] as? Int == 1)
    }

    @Test
    func `serve cache does not reuse a label for a different account identity`() async throws {
        let (wallClock, cache) = makeServeTestCache()

        _ = await BarsCLI.cachedServeResponse(
            key: "usage:",
            cache: cache,
            refreshInterval: 0.05,
            requestTimeout: 1)
        {
            Self.response(
                #"[{"provider":"opencode","account":"shared","call":1}]"#,
                usageCacheKeys: ["account-1"])
        }
        wallClock.advance(by: 0.05)

        let refreshed = await BarsCLI.cachedServeResponse(
            key: "usage:",
            cache: cache,
            refreshInterval: 0.05,
            requestTimeout: 1)
        {
            Self.response(
                """
                [
                  {"provider":"opencode","account":"shared","error":{"message":"transient"}},
                  {"provider":"antigravity","account":"work","call":2}
                ]
                """,
                usageCacheKeys: ["account-2", "account-3"])
        }
        let rows = try Self.jsonRows(refreshed)

        #expect(Self.row(rows, provider: "opencode", account: "shared")?["error"] != nil)
        #expect(Self.row(rows, provider: "antigravity", account: "work")?["call"] as? Int == 2)
    }

    @Test
    func `serve cache does not use whole fallback after an account switch`() async throws {
        let (wallClock, cache) = makeServeTestCache()

        _ = await BarsCLI.cachedServeResponse(
            key: "usage:",
            cache: cache,
            refreshInterval: 0.05,
            requestTimeout: 1)
        {
            Self.response(
                #"[{"provider":"opencode","account":"shared","call":1}]"#,
                usageCacheKeys: ["account-1"])
        }
        wallClock.advance(by: 0.05)

        let failed = await BarsCLI.cachedServeResponse(
            key: "usage:",
            cache: cache,
            refreshInterval: 0.05,
            requestTimeout: 1)
        {
            Self.response(
                #"[{"provider":"opencode","account":"shared","error":{"message":"transient"}}]"#,
                usageCacheKeys: ["account-2"])
        }
        let row = try #require(Self.jsonRows(failed).first)

        #expect(row["call"] == nil)
        #expect(row["error"] != nil)

        let timedOut = await BarsCLI.cachedServeResponse(
            key: "usage:",
            cache: cache,
            refreshInterval: 0.05,
            requestTimeout: 0.01)
        {
            await Self.hangPastRequestDeadline()
            return Self.response(
                #"[{"provider":"opencode","account":"shared","call":3}]"#,
                usageCacheKeys: ["account-2"])
        }

        #expect(timedOut.status == .gatewayTimeout)
        #expect(!Self.bodyString(timedOut).contains("\"call\":1"))
    }

    @Test
    func `serve cache prunes accounts absent from a successful snapshot`() async throws {
        let (wallClock, cache) = makeServeTestCache()

        _ = await BarsCLI.cachedServeResponse(
            key: "usage:",
            cache: cache,
            refreshInterval: 0.05,
            requestTimeout: 1)
        {
            Self.response(#"[{"provider":"opencode","account":"shared","call":1}]"#)
        }
        wallClock.advance(by: 0.05)

        _ = await BarsCLI.cachedServeResponse(
            key: "usage:",
            cache: cache,
            refreshInterval: 0.05,
            requestTimeout: 1)
        {
            Self.response(#"[{"provider":"antigravity","account":"work","call":2}]"#)
        }
        wallClock.advance(by: 0.05)

        let refreshed = await BarsCLI.cachedServeResponse(
            key: "usage:",
            cache: cache,
            refreshInterval: 0.05,
            requestTimeout: 1)
        {
            Self.response("""
            [
              {"provider":"opencode","account":"shared","error":{"message":"transient"}},
              {"provider":"antigravity","account":"work","call":3}
            ]
            """)
        }
        let rows = try Self.jsonRows(refreshed)

        #expect(Self.row(rows, provider: "opencode", account: "shared")?["error"] != nil)
        #expect(Self.row(rows, provider: "antigravity", account: "work")?["call"] as? Int == 3)
    }

    @Test
    func `serve cache fails closed when all-error rows have ambiguous identities`() async throws {
        let (wallClock, cache) = makeServeTestCache()

        _ = await BarsCLI.cachedServeResponse(
            key: "usage:",
            cache: cache,
            refreshInterval: 0.05,
            requestTimeout: 1)
        {
            Self.response(
                """
                [
                  {"provider":"opencode","account":"shared","slot":"first","call":1},
                  {"provider":"opencode","account":"shared","slot":"second","call":1},
                  {"provider":"antigravity","account":"work","call":1}
                ]
                """,
                usageCacheKeys: [nil, nil, nil])
        }
        wallClock.advance(by: 0.05)

        let failed = await BarsCLI.cachedServeResponse(
            key: "usage:",
            cache: cache,
            refreshInterval: 0.05,
            requestTimeout: 1)
        {
            Self.response(
                """
                [
                  {
                    "provider":"opencode",
                    "account":"shared",
                    "slot":"first",
                    "error":{"message":"transient"}
                  },
                  {
                    "provider":"opencode",
                    "account":"shared",
                    "slot":"second",
                    "error":{"message":"transient"}
                  },
                  {"provider":"antigravity","account":"work","error":{"message":"transient"}}
                ]
                """,
                usageCacheKeys: [nil, nil, nil])
        }
        let rows = try Self.jsonRows(failed)

        #expect(rows.count == 3)
        #expect(rows.allSatisfy { $0["call"] == nil })
        #expect(rows.allSatisfy { $0["error"] != nil })
    }

    @Test
    func `serve cache does not whole-fallback ambiguous usage after timeout`() async {
        let (wallClock, cache) = makeServeTestCache()

        _ = await BarsCLI.cachedServeResponse(
            key: "usage:",
            cache: cache,
            refreshInterval: 0.05,
            requestTimeout: 1)
        {
            Self.response(
                #"[{"provider":"antigravity","account":"first@example.com","call":1}]"#,
                usageCacheKeys: [nil])
        }
        wallClock.advance(by: 0.05)

        let timedOut = await BarsCLI.cachedServeResponse(
            key: "usage:",
            cache: cache,
            refreshInterval: 0.05,
            requestTimeout: 0.01)
        {
            await Self.hangPastRequestDeadline()
            return Self.response(
                #"[{"provider":"antigravity","account":"second@example.com","call":2}]"#,
                usageCacheKeys: [nil])
        }

        #expect(timedOut.status == .gatewayTimeout)
        #expect(!Self.bodyString(timedOut).contains("first@example.com"))
        #expect(!Self.bodyString(timedOut).contains("\"call\":1"))
    }

    @Test
    func `serve cache mixed identities do not enable timeout fallback`() async {
        let (wallClock, cache) = makeServeTestCache()

        _ = await BarsCLI.cachedServeResponse(
            key: "usage:",
            cache: cache,
            refreshInterval: 0.05,
            requestTimeout: 1)
        {
            Self.response(
                """
                [
                  {"provider":"opencode","account":"stable@example.com","call":1},
                  {"provider":"antigravity","account":"ambient@example.com","call":1}
                ]
                """,
                usageCacheKeys: ["account-1", nil])
        }
        wallClock.advance(by: 0.05)

        let timedOut = await BarsCLI.cachedServeResponse(
            key: "usage:",
            cache: cache,
            refreshInterval: 0.05,
            requestTimeout: 0.01)
        {
            await Self.hangPastRequestDeadline()
            return Self.response("[]", usageCacheKeys: [])
        }
        #expect(timedOut.status == .gatewayTimeout)
        #expect(!Self.bodyString(timedOut).contains("stable@example.com"))
        #expect(!Self.bodyString(timedOut).contains("ambient@example.com"))
    }

    @Test
    func `serve stale ttl is bounded and disabled without caching`() {
        #expect(BarsCLI.serveStaleTTL(refreshInterval: 0) == 0)
        #expect(BarsCLI.serveStaleTTL(refreshInterval: 1) == 300)
        #expect(BarsCLI.serveStaleTTL(refreshInterval: 60) == 600)
        #expect(BarsCLI.serveStaleTTL(refreshInterval: 1800) == 3600)
        #expect(BarsCLI.serveStaleTTL(refreshInterval: 86401) == 3600)
        #expect(BarsCLI.serveStaleTTL(refreshInterval: .infinity) == 3600)
    }

    @Test
    func `serve cache prunes stale variants from old configurations`() async {
        let cache = CLIServeResponseCache()
        let startedAt = Date(timeIntervalSince1970: 1000)
        let policy = CLIServeResponseCache.CachePolicy(
            ttl: 0,
            staleTTL: CLIServeResponseCache.maximumStaleTTL)

        _ = await cache.completeFetch(
            Self.response(#"{"status":"ok"}"#),
            for: "config:old",
            policy: policy,
            now: startedAt,
            shouldCache: true)

        _ = await cache.completeFetch(
            Self.response(
                #"[{"provider":"opencode","call":1}]"#,
                usageCacheKeys: ["account-1"]),
            for: "usage:old",
            policy: policy,
            now: startedAt,
            shouldCache: true)
        #expect(await cache.cachedStaleVariantCount() == 2)

        let expiredAt = startedAt.addingTimeInterval(CLIServeResponseCache.maximumStaleTTL + 1)
        _ = await cache.cachedResponse(for: "config:new", now: expiredAt)
        #expect(await cache.cachedStaleVariantCount() == 0)
        _ = await cache.completeFetch(
            Self.response(#"{"status":"ok"}"#),
            for: "config:new",
            policy: policy,
            now: expiredAt,
            shouldCache: false)
    }

    @Test
    func `serve helper idle window outlives the refresh cadence`() {
        #expect(BarsCLI.serveCLISessionIdleWindow(refreshInterval: 0) == 180)
        #expect(BarsCLI.serveCLISessionIdleWindow(refreshInterval: 60) == 180)
        #expect(BarsCLI.serveCLISessionIdleWindow(refreshInterval: 300) == 360)
    }

    @Test
    func `local HTTP server stops its accept loop`() async throws {
        let listening = ServeListeningSignal()
        let server = CLILocalHTTPServer(host: "127.0.0.1", port: 0) { _ in
            Self.response(#"{"status":"ok"}"#)
        }
        let task = Task {
            try await server.run {
                listening.signal()
            }
        }

        await listening.wait()
        server.stop()
        try await task.value
    }

    @Test
    func `serve request timeout zero disables the deadline`() async {
        let cache = CLIServeResponseCache()

        let response = await BarsCLI.cachedServeResponse(
            key: "usage:",
            cache: cache,
            refreshInterval: 0,
            requestTimeout: 0)
        {
            try? await Task.sleep(nanoseconds: 80_000_000)
            return Self.response("[{\"provider\":\"opencode\",\"slow\":true}]")
        }

        #expect(response.status == .ok)
        #expect(Self.bodyString(response).contains("\"slow\":true"))
    }

    private static func parsedRequest(host: String) throws -> CLILocalHTTPRequest {
        let raw = "GET /usage?provider=claude HTTP/1.1\r\nHost: \(host)\r\n\r\n"
        return try CLILocalHTTPRequest.parse(Data(raw.utf8)).get()
    }

    private static func expectParseFailure(
        raw: String,
        _ expected: CLILocalHTTPRequestParseError,
        allowedHosts: CLILocalHTTPAllowedHosts = .loopbackOnly)
    {
        switch CLILocalHTTPRequest.parse(Data(raw.utf8), allowedHosts: allowedHosts) {
        case .success:
            Issue.record("Expected \(expected)")
        case let .failure(error):
            #expect(error == expected)
        }
    }

    /// A refresh stand-in that outlives any request deadline. Deliberately uncancellable:
    /// `try? await Task.sleep` returns immediately once the coordinator cancels the timed-out
    /// operation, and that salvaged "real" response then races (and can beat) the timeout value.
    private static func hangPastRequestDeadline() async {
        await withUnsafeContinuation { continuation in
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) { continuation.resume() }
        }
    }

    private static func response(
        _ body: String,
        status: CLIHTTPStatus = .ok,
        usageCacheKeys: [String?]? = nil) -> CLILocalHTTPResponse
    {
        let data = Data(body.utf8)
        return CLILocalHTTPResponse(
            status: status,
            body: data,
            usageCacheKeys: usageCacheKeys ?? Self.syntheticUsageCacheKeys(data))
    }

    private static func bodyString(_ response: CLILocalHTTPResponse) -> String {
        String(data: response.body, encoding: .utf8) ?? ""
    }

    private static func jsonRows(_ response: CLILocalHTTPResponse) throws -> [[String: Any]] {
        try #require(JSONSerialization.jsonObject(with: response.body) as? [[String: Any]])
    }

    private static func row(
        _ rows: [[String: Any]],
        provider: String,
        account: String) -> [String: Any]?
    {
        rows.first {
            $0["provider"] as? String == provider
                && $0["account"] as? String == account
        }
    }

    private static func row(_ rows: [[String: Any]], provider: String) -> [String: Any]? {
        rows.first { $0["provider"] as? String == provider }
    }

    private static func syntheticUsageCacheKeys(_ data: Data) -> [String?]? {
        guard let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        return rows.map { row in
            guard let provider = row["provider"] as? String else { return nil }
            let account = row["account"] as? String ?? "default"
            return "test:\(provider):\(account)"
        }
    }
}

private actor ServeTestCounter {
    private var value = 0

    func increment() -> Int {
        self.value += 1
        return self.value
    }

    func current() -> Int {
        self.value
    }
}
