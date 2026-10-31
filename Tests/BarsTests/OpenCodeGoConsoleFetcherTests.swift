import Foundation
import Testing
@testable import BarsCore

/// The Console path issues several requests per read, so it needs its own URLProtocol stub state.
@Suite(.serialized)
struct OpenCodeGoConsoleFetcherTests {
    private final class RequestRecorder<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [Value] = []

        func append(_ value: Value) {
            self.lock.lock()
            defer { self.lock.unlock() }
            self.storage.append(value)
        }

        var values: [Value] {
            self.lock.lock()
            defer { self.lock.unlock() }
            return self.storage
        }
    }

    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [OpenCodeGoConsoleStubURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func makeResponse(
        url: URL,
        body: String,
        contentType: String) -> (HTTPURLResponse, Data)
    {
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": contentType])!
        return (response, Data(body.utf8))
    }

    @Test
    func `console meters win over the whole-percent public API`() async throws {
        defer { OpenCodeGoConsoleStubURLProtocol.handler = nil }
        let publicBody = try #require(String(
            data: JSONSerialization.data(withJSONObject: ["usage": [
                "rolling": ["percent": 0, "resetsAt": "2026-10-31T02:38:22.000Z"],
                "weekly": ["percent": 3, "resetsAt": "2026-11-02T00:00:00.000Z"],
                "monthly": ["percent": 1, "resetsAt": "2026-11-29T19:07:22.000Z"],
            ]]),
            encoding: .utf8))
        let meterBody = """
        {"access":{"startsAt":"2026-10-29T19:07:22.000Z","endsAt":"2026-11-29T19:07:22.000Z",
         "meters":{
           "fiveHour":{"resetsAt":"2026-10-31T02:38:22.000Z",
             "limitMicroCents":"1200000000","usedMicroCents":"11866776"},
           "week":{"resetsAt":"2026-11-02T00:00:00.000Z",
             "limitMicroCents":"3000000000","usedMicroCents":"110924908"},
           "month":{"resetsAt":"2026-11-29T19:07:22.000Z",
             "limitMicroCents":"6000000000","usedMicroCents":"110924908"}}}}
        """
        let exportBody = """
        day,user_type,user_id,user_name,provider,model,requests,input_tokens,output_tokens,\
        cache_read_tokens,cache_write_5m_tokens,cache_write_1h_tokens,cost_micro_cents,cost_usd\r
        2026-10-30,member,acc_fixture,fixture@example.com,opencode-go,deepseek-v4.1-flash,\
        422,1888025,256290,33984384,0,0,57144212,0.57144212\r
        """
        let summaryBody = """
        {"totalRequests":"422","totalInputTokens":"1888025","totalOutputTokens":"256290",
         "totalCacheReadTokens":"33984384","totalCacheWrite5mTokens":"0","totalCacheWrite1hTokens":"0",
         "totalCostMicroCents":"57144212","services":[]}
        """
        let modelsBody = """
        {"items":[{"model":"deepseek-v4.1-flash","provider":"opencode-go","totalRequests":"422",
         "totalInputTokens":"1888025","totalOutputTokens":"256290","totalCacheReadTokens":"33984384",
         "totalCacheWrite5mTokens":"0","totalCacheWrite1hTokens":"0","totalCostMicroCents":"57144212"}],
         "pageInfo":{"page":1,"pageSize":10,"total":1,"pageCount":1}}
        """
        let requests = RequestRecorder<URLRequest>()
        OpenCodeGoConsoleStubURLProtocol.handler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            requests.append(request)
            let body: String = switch url.path {
            case "/console/api/go/status": meterBody
            case "/console/api/v2/usage/export": exportBody
            case "/console/api/usage/summary": summaryBody
            case "/console/api/usage/models": modelsBody
            default: publicBody
            }
            return self.makeResponse(
                url: url,
                body: body,
                contentType: url.path == "/console/api/v2/usage/export" ? "text/csv" : "application/json")
        }

        let now = try #require(ISO8601DateFormatter().date(from: "2026-10-30T22:00:00Z"))
        let snapshot = try await OpenCodeGoUsageFetcher.fetchAPIUsage(
            apiKey: "go_secret",
            timeout: 2,
            now: now,
            session: self.makeSession())

        // The public API never runs: the Console answered with exact micro-cent meters.
        #expect(!requests.values.contains { $0.url?.path == "/zen/go/v1/usage" })
        #expect(requests.values.first?.url?.path == "/console/api/go/status")
        #expect(abs(snapshot.monthlyUsagePercent - 1.84874847) < 0.000001)
        #expect(abs(snapshot.weeklyUsagePercent - 3.6974969) < 0.000001)
        #expect(snapshot.hasWeeklyUsage)
        #expect(snapshot.hasMonthlyUsage)

        // Billed spend and token counts ride along for the cost and token history surfaces.
        let billed = try #require(snapshot.billed)
        #expect(billed.costUSD == 0.57144212)
        #expect(billed.requests == 422)
        #expect(billed.models.map(\.model) == ["deepseek-v4.1-flash"])
        #expect(snapshot.daily.map(\.date) == ["2026-10-30"])

        let usage = snapshot.toUsageSnapshot()
        let tertiary = try #require(usage.tertiary)
        #expect(usage.primary?.usedPercent == 0.988898)
        #expect(tertiary.usedPercent == snapshot.monthlyUsagePercent)
    }
}

/// Suite-local stub: the neighbouring fetcher suite has its own static handler, and Swift Testing
/// does not serialize across suites, so sharing one would let either suite answer for the other.
private final class OpenCodeGoConsoleStubURLProtocol: URLProtocol {
    private static let handlerBox = LockIsolated<((URLRequest) throws -> (HTTPURLResponse, Data))?>(nil)
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))? {
        get { Self.handlerBox.value }
        set { Self.handlerBox.setValue(newValue) }
    }

    override static func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "opencode.ai"
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            self.client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(self.request)
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: data)
            self.client?.urlProtocolDidFinishLoading(self)
        } catch {
            self.client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
