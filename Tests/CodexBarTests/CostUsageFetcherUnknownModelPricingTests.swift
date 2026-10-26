import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CodexBarCore

struct CostUsageFetcherUnknownModelPricingTests {
    @Test
    func `fetcher reprices a bare claude vendor model after an on demand catalog refresh`() async throws {
        let fixture = try UnknownModelPricingFixture()
        defer { fixture.environment.cleanup() }
        let assistant: [String: Any] = [
            "type": "assistant",
            "timestamp": fixture.environment.isoString(for: fixture.day),
            "message": [
                "model": "deepseek-v4-flash",
                "usage": [
                    "input_tokens": 100,
                    "cache_creation_input_tokens": 0,
                    "cache_read_input_tokens": 0,
                    "output_tokens": 10,
                ],
            ],
        ]
        _ = try fixture.environment.writeClaudeProjectFile(
            relativePath: "project-a/unknown-vendor-model.jsonl",
            contents: fixture.environment.jsonl([assistant]))

        let snapshot = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .claude,
            now: fixture.day,
            refreshPricingInBackground: false,
            scannerOptions: fixture.options,
            modelsDevClient: ModelsDevClient(transport: CostUsageFetcherModelsDevTransport(
                data: fixture.refreshedCatalog)))

        let breakdown = try #require(snapshot.daily.first?.modelBreakdowns?.first)
        #expect(breakdown.modelName == "deepseek-v4-flash")
        #expect(abs((breakdown.costUSD ?? 0) - 0.0000168) < 0.0000001)
    }
}

private struct UnknownModelPricingFixture {
    let environment: CostUsageTestEnvironment
    let day: Date
    let options: CostUsageScanner.Options
    let refreshedCatalog: Data

    init() throws {
        let environment = try CostUsageTestEnvironment()
        self.environment = environment
        self.day = try environment.makeLocalNoon(year: 2026, month: 4, day: 12)
        let oldCatalog = try JSONDecoder().decode(ModelsDevCatalog.self, from: Data("""
        {
          "openai": {
            "id": "openai",
            "models": { "gpt-old": { "id": "gpt-old", "cost": { "input": 1, "output": 4 } } }
          },
          "anthropic": {
            "id": "anthropic",
            "models": { "claude-old": { "id": "claude-old", "cost": { "input": 3, "output": 15 } } }
          }
        }
        """.utf8))
        ModelsDevCache.save(
            catalog: oldCatalog,
            fetchedAt: self.day.addingTimeInterval(-901),
            cacheRoot: environment.cacheRoot)

        self.refreshedCatalog = Data("""
        {
          "openai": {
            "id": "openai",
            "models": { "gpt-new": { "id": "gpt-new", "cost": { "input": 2, "output": 8 } } }
          },
          "opencode-go": {
            "id": "opencode-go",
            "models": {
              "deepseek-v4-flash": {
                "id": "deepseek-v4-flash",
                "cost": { "input": 0.07, "output": 0.14 }
              }
            }
          },
          "deepseek": {
            "id": "deepseek",
            "models": {
              "deepseek-v4-flash": {
                "id": "deepseek-v4-flash",
                "cost": { "input": 0.14, "output": 0.28 }
              }
            }
          },
          "anthropic": {
            "id": "anthropic",
            "models": { "claude-new": { "id": "claude-new", "cost": { "input": 3, "output": 15 } } }
          }
        }
        """.utf8)
        self.options = CostUsageScanner.Options(
            claudeProjectsRoots: [environment.claudeProjectsRoot],
            cacheRoot: environment.cacheRoot)
    }
}

private struct CostUsageFetcherModelsDevTransport: ModelsDevHTTPTransport {
    let data: Data

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil)!
        return (self.data, response)
    }
}
