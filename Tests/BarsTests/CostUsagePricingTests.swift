import Foundation
import Testing
@testable import BarsCore

struct CostUsagePricingTests {
    @Test
    func `normalizes claude opus41 dated variants`() {
        #expect(CostUsagePricing.normalizeClaudeModel("claude-opus-4-1-20250805") == "claude-opus-4-1")
    }

    @Test
    func `claude cost supports opus41 dated variant`() {
        let cost = CostUsagePricing.claudeCostUSD(
            model: "claude-opus-4-1-20250805",
            inputTokens: 10,
            cacheReadInputTokens: 0,
            cacheCreationInputTokens: 0,
            outputTokens: 5,
            modelsDevCatalog: ModelsDevCatalog(providers: [:]))
        #expect(cost != nil)
    }

    @Test
    func `claude cost supports opus46 dated variant`() {
        let cost = CostUsagePricing.claudeCostUSD(
            model: "claude-opus-4-6-20260205",
            inputTokens: 10,
            cacheReadInputTokens: 0,
            cacheCreationInputTokens: 0,
            outputTokens: 5,
            modelsDevCatalog: ModelsDevCatalog(providers: [:]))
        #expect(cost != nil)
    }

    @Test
    func `claude cost supports opus47`() {
        let cost = CostUsagePricing.claudeCostUSD(
            model: "claude-opus-4-7",
            inputTokens: 10,
            cacheReadInputTokens: 0,
            cacheCreationInputTokens: 0,
            outputTokens: 5,
            modelsDevCatalog: ModelsDevCatalog(providers: [:]))
        let expected = (10.0 * 5e-6) + (5.0 * 2.5e-5)
        #expect(cost == expected)
    }

    @Test
    func `claude cost supports opus48`() throws {
        // Point at a fresh, empty cache root so the models.dev lookup misses and this
        // exercises the built-in fallback table specifically — not a local cache hit.
        let emptyCacheRoot = try Self.cacheRoot()
        let cost = CostUsagePricing.claudeCostUSD(
            model: "claude-opus-4-8",
            inputTokens: 10,
            cacheReadInputTokens: 0,
            cacheCreationInputTokens: 0,
            outputTokens: 5,
            modelsDevCacheRoot: emptyCacheRoot)
        let expected = (10.0 * 5e-6) + (5.0 * 2.5e-5)
        #expect(cost == expected)
    }

    @Test
    func `claude cost supports fable5 bundled fallback`() throws {
        let emptyCacheRoot = try Self.cacheRoot()
        let cost = CostUsagePricing.claudeCostUSD(
            model: "claude-fable-5",
            inputTokens: 100,
            cacheReadInputTokens: 20,
            cacheCreationInputTokens: 10,
            outputTokens: 5,
            modelsDevCacheRoot: emptyCacheRoot)
        let expected = (100.0 * 1e-5) + (20.0 * 1e-6) + (10.0 * 1.25e-5) + (5.0 * 5e-5)
        #expect(cost == expected)
    }

    @Test
    func `claude cost preserves historical sonnet46 long context pricing`() throws {
        let emptyCacheRoot = try Self.cacheRoot()
        let historical = CostUsagePricing.claudeCostUSD(
            model: "claude-sonnet-4-6",
            inputTokens: 240_000,
            cacheReadInputTokens: 0,
            cacheCreationInputTokens: 0,
            outputTokens: 0,
            pricingDate: Date(timeIntervalSince1970: 1_773_359_999),
            modelsDevCacheRoot: emptyCacheRoot)
        let current = CostUsagePricing.claudeCostUSD(
            model: "claude-sonnet-4-6",
            inputTokens: 240_000,
            cacheReadInputTokens: 0,
            cacheCreationInputTokens: 0,
            outputTokens: 0,
            pricingDate: Date(timeIntervalSince1970: 1_773_360_000),
            modelsDevCacheRoot: emptyCacheRoot)

        #expect(historical == 1.44)
        #expect(current == 0.72)
    }

    @Test
    func `claude cost ignores stale sonnet46 threshold catalog after cutover`() throws {
        let cacheRoot = try Self.seedModelsDevCache("""
        {
          "anthropic": {
            "id": "anthropic",
            "models": {
              "claude-sonnet-4-6": {
                "id": "claude-sonnet-4-6",
                "cost": {
                  "input": 3,
                  "output": 15,
                  "cache_read": 0.3,
                  "cache_write": 3.75,
                  "context_over_200k": {
                    "input": 6,
                    "output": 22.5,
                    "cache_read": 0.6,
                    "cache_write": 7.5
                  }
                }
              }
            }
          }
        }
        """)
        let cost = CostUsagePricing.claudeCostUSD(
            model: "claude-sonnet-4-6",
            inputTokens: 240_000,
            cacheReadInputTokens: 0,
            cacheCreationInputTokens: 0,
            outputTokens: 0,
            pricingDate: Date(timeIntervalSince1970: 1_773_360_000),
            modelsDevCacheRoot: cacheRoot)

        #expect(cost == 0.72)
    }

    @Test
    func `claude cost prices one hour cache writes separately`() throws {
        let emptyCacheRoot = try Self.cacheRoot()
        let cost = CostUsagePricing.claudeCostUSD(
            model: "claude-fable-5",
            inputTokens: 100,
            cacheReadInputTokens: 20,
            cacheCreationInputTokens: 30,
            cacheCreationInputTokens1h: 20,
            outputTokens: 5,
            modelsDevCacheRoot: emptyCacheRoot)
        let expected = (100.0 * 1e-5)
            + (20.0 * 1e-6)
            + (10.0 * 1.25e-5)
            + (20.0 * 2e-5)
            + (5.0 * 5e-5)
        #expect(cost == expected)
    }

    @Test
    func `claude cost applies long context rates across cache write durations`() throws {
        let cacheRoot = try Self.seedModelsDevCache("""
        {
          "anthropic": {
            "id": "anthropic",
            "models": {
              "claude-threshold-model": {
                "id": "claude-threshold-model",
                "cost": {
                  "input": 3,
                  "output": 15,
                  "cache_read": 0.3,
                  "cache_write": 3.75,
                  "context_over_200k": {
                    "input": 6,
                    "output": 22.5,
                    "cache_read": 0.6,
                    "cache_write": 7.5
                  }
                }
              }
            }
          }
        }
        """)
        let cost = CostUsagePricing.claudeCostUSD(
            model: "claude-threshold-model",
            inputTokens: 0,
            cacheReadInputTokens: 0,
            cacheCreationInputTokens: 240_000,
            cacheCreationInputTokens1h: 120_000,
            outputTokens: 0,
            modelsDevCacheRoot: cacheRoot)
        let expected = (120_000.0 * 12e-6)
            + (120_000.0 * 7.5e-6)
        #expect(cost == expected)
    }

    @Test
    func `claude sonnet46 uses standard pricing across full context`() throws {
        let emptyCacheRoot = try Self.cacheRoot()
        let cost = CostUsagePricing.claudeCostUSD(
            model: "claude-sonnet-4-6",
            inputTokens: 0,
            cacheReadInputTokens: 0,
            cacheCreationInputTokens: 240_000,
            outputTokens: 0,
            modelsDevCacheRoot: emptyCacheRoot)
        #expect(cost == 240_000.0 * 3.75e-6)
    }

    @Test
    func `claude cost returns nil for unknown models`() {
        let cost = CostUsagePricing.claudeCostUSD(
            model: "glm-4.6",
            inputTokens: 100,
            cacheReadInputTokens: 500,
            cacheCreationInputTokens: 0,
            outputTokens: 40,
            modelsDevCatalog: ModelsDevCatalog(providers: [:]))
        #expect(cost == nil)
    }

    @Test
    func `claude cost prefers models dev cache with threshold pricing`() throws {
        let root = try Self.seedModelsDevCache("""
        {
          "anthropic": {
            "id": "anthropic",
            "models": {
              "claude-sonnet-4-6": {
                "id": "claude-sonnet-4-6",
                "cost": {
                  "input": 3,
                  "output": 15,
                  "cache_read": 0.3,
                  "cache_write": 3.75,
                  "context_over_200k": {
                    "input": 6,
                    "output": 22.5,
                    "cache_read": 0.6,
                    "cache_write": 7.5
                  }
                }
              }
            }
          }
        }
        """)

        let cost = CostUsagePricing.claudeCostUSD(
            model: "claude-sonnet-4-6",
            inputTokens: 200_010,
            cacheReadInputTokens: 5,
            cacheCreationInputTokens: 5,
            outputTokens: 5,
            modelsDevCacheRoot: root)

        let expected = (200_010.0 * 6e-6)
            + (5.0 * 0.6e-6)
            + (5.0 * 7.5e-6)
            + (5.0 * 22.5e-6)
        #expect(cost == expected)
    }

    @Test
    func `claude cost prices bare first-party model IDs from vendor catalogs`() throws {
        let root = try Self.seedModelsDevCache("""
        {
          "anthropic": {
            "id": "anthropic",
            "models": {
              "claude-sonnet-4-6": {
                "id": "claude-sonnet-4-6",
                "cost": { "input": 3, "output": 15 }
              },
              "deepseek-v4-flash": {
                "id": "deepseek-v4-flash",
                "cost": { "input": 99, "output": 199 }
              }
            }
          },
          "openai": {
            "id": "openai",
            "models": {
              "claude-sonnet-4-6": {
                "id": "claude-sonnet-4-6",
                "cost": { "input": 1, "output": 2 }
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
          "opencode-go": {
            "id": "opencode-go",
            "models": {
              "deepseek-v4-flash": {
                "id": "deepseek-v4-flash",
                "cost": { "input": 0.07, "output": 0.14 }
              }
            }
          }
        }
        """)

        let bare = CostUsagePricing.claudeCostUSD(
            model: "deepseek-v4-flash",
            inputTokens: 100,
            cacheReadInputTokens: 0,
            cacheCreationInputTokens: 0,
            outputTokens: 5,
            modelsDevCacheRoot: root)
        let prefixed = CostUsagePricing.claudeCostUSD(
            model: "opencode-go/deepseek-v4-flash",
            inputTokens: 100,
            cacheReadInputTokens: 0,
            cacheCreationInputTokens: 0,
            outputTokens: 5,
            modelsDevCacheRoot: root)
        let anthropic = CostUsagePricing.claudeCostUSD(
            model: "claude-sonnet-4-6",
            inputTokens: 10,
            cacheReadInputTokens: 0,
            cacheCreationInputTokens: 0,
            outputTokens: 5,
            modelsDevCacheRoot: root)

        #expect(bare == (100.0 * 0.14e-6) + (5.0 * 0.28e-6))
        #expect(prefixed == (100.0 * 0.07e-6) + (5.0 * 0.14e-6))
        #expect(anthropic == (10.0 * 3e-6) + (5.0 * 15e-6))
        #expect(CostUsagePricing.claudeModelsDevPricingTargets(for: "deepseek-v4-flash").first?.providerID
            == "deepseek")
        #expect(CostUsagePricing.claudeModelsDevPricingTargets(for: "claude-sonnet-4-6").first?.providerID
            == "anthropic")
        #expect(Set(CostUsagePricing.claudeFirstPartyModelsDevProviderIDs).isSuperset(of: [
            "anthropic",
            "openai",
            "google",
            "moonshot",
            "kimi-for-coding",
            "minimax",
            "deepseek",
        ]))
    }

    @Test
    func `claude cost rejects an ambiguous bare model catalog collision`() throws {
        let root = try Self.seedModelsDevCache("""
        {
          "openai": {
            "id": "openai",
            "models": {
              "shared-model": {
                "id": "shared-model",
                "cost": { "input": 1, "output": 2 }
              }
            }
          },
          "google": {
            "id": "google",
            "models": {
              "shared-model": {
                "id": "shared-model",
                "cost": { "input": 3, "output": 4 }
              }
            }
          }
        }
        """)

        let cost = CostUsagePricing.claudeCostUSD(
            model: "shared-model",
            inputTokens: 100,
            cacheReadInputTokens: 0,
            cacheCreationInputTokens: 0,
            outputTokens: 5,
            modelsDevCacheRoot: root)

        #expect(cost == nil)
    }

    @Test
    func `claude cost does not cross charge a prefixed route onto first-party rates`() throws {
        let root = try Self.seedModelsDevCache("""
        {
          "deepseek": {
            "id": "deepseek",
            "models": {
              "deepseek-v4-flash": {
                "id": "deepseek-v4-flash",
                "cost": { "input": 0.14, "output": 0.28 }
              }
            }
          }
        }
        """)

        let cost = CostUsagePricing.claudeCostUSD(
            model: "opencode-go/deepseek-v4-flash",
            inputTokens: 100,
            cacheReadInputTokens: 0,
            cacheCreationInputTokens: 0,
            outputTokens: 5,
            modelsDevCacheRoot: root)
        let unknownRoute = CostUsagePricing.claudeCostUSD(
            model: "unknown-route/deepseek-v4-flash",
            inputTokens: 100,
            cacheReadInputTokens: 0,
            cacheCreationInputTokens: 0,
            outputTokens: 5,
            modelsDevCacheRoot: root)

        #expect(cost == nil)
        #expect(unknownRoute == nil)
    }

    private static func seedModelsDevCache(_ json: String) throws -> URL {
        let root = try Self.cacheRoot()
        let catalog = try JSONDecoder().decode(ModelsDevCatalog.self, from: Data(json.utf8))
        ModelsDevCache.save(catalog: catalog, fetchedAt: Date(), cacheRoot: root)
        return root
    }

    private static func modelsDevArtifact(_ json: String) throws -> ModelsDevCacheArtifact {
        let catalog = try JSONDecoder().decode(ModelsDevCatalog.self, from: Data(json.utf8))
        return ModelsDevCacheArtifact(
            version: ModelsDevCache.artifactVersion,
            fetchedAt: Date(timeIntervalSince1970: 0),
            catalog: catalog)
    }

    private static func cacheRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bars-pricing-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
