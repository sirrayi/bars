import Foundation

enum CostUsagePricing {
    struct ClaudePricing {
        let inputCostPerToken: Double
        let outputCostPerToken: Double
        let cacheCreationInputCostPerToken: Double
        let cacheReadInputCostPerToken: Double

        let thresholdTokens: Int?
        let inputCostPerTokenAboveThreshold: Double?
        let outputCostPerTokenAboveThreshold: Double?
        let cacheCreationInputCostPerTokenAboveThreshold: Double?
        let cacheReadInputCostPerTokenAboveThreshold: Double?
    }

    struct ClaudeCostTokens {
        let input: Int
        let cacheRead: Int
        let cacheCreation: Int
        let cacheCreation1h: Int
        let output: Int
    }

    static func optionalPricingFingerprint(_ value: Double?) -> String {
        guard let value else { return "nil" }
        return String(format: "%.17g", value)
    }

    private static let claude: [String: ClaudePricing] = [
        "claude-fable-5": ClaudePricing(
            inputCostPerToken: 1e-5,
            outputCostPerToken: 5e-5,
            cacheCreationInputCostPerToken: 1.25e-5,
            cacheReadInputCostPerToken: 1e-6,
            thresholdTokens: nil,
            inputCostPerTokenAboveThreshold: nil,
            outputCostPerTokenAboveThreshold: nil,
            cacheCreationInputCostPerTokenAboveThreshold: nil,
            cacheReadInputCostPerTokenAboveThreshold: nil),
        "claude-haiku-4-5-20251001": ClaudePricing(
            inputCostPerToken: 1e-6,
            outputCostPerToken: 5e-6,
            cacheCreationInputCostPerToken: 1.25e-6,
            cacheReadInputCostPerToken: 1e-7,
            thresholdTokens: nil,
            inputCostPerTokenAboveThreshold: nil,
            outputCostPerTokenAboveThreshold: nil,
            cacheCreationInputCostPerTokenAboveThreshold: nil,
            cacheReadInputCostPerTokenAboveThreshold: nil),
        "claude-haiku-4-5": ClaudePricing(
            inputCostPerToken: 1e-6,
            outputCostPerToken: 5e-6,
            cacheCreationInputCostPerToken: 1.25e-6,
            cacheReadInputCostPerToken: 1e-7,
            thresholdTokens: nil,
            inputCostPerTokenAboveThreshold: nil,
            outputCostPerTokenAboveThreshold: nil,
            cacheCreationInputCostPerTokenAboveThreshold: nil,
            cacheReadInputCostPerTokenAboveThreshold: nil),
        // Mythos is served to verified organizations only and is absent from the models.dev
        // anthropic catalog. Rates: https://platform.claude.com/docs/en/about-claude/pricing
        "claude-mythos-5": ClaudePricing(
            inputCostPerToken: 1e-5,
            outputCostPerToken: 5e-5,
            cacheCreationInputCostPerToken: 1.25e-5,
            cacheReadInputCostPerToken: 1e-6,
            thresholdTokens: nil,
            inputCostPerTokenAboveThreshold: nil,
            outputCostPerTokenAboveThreshold: nil,
            cacheCreationInputCostPerTokenAboveThreshold: nil,
            cacheReadInputCostPerTokenAboveThreshold: nil),
        "claude-mythos-5-1": ClaudePricing(
            inputCostPerToken: 1e-5,
            outputCostPerToken: 5e-5,
            cacheCreationInputCostPerToken: 1.25e-5,
            cacheReadInputCostPerToken: 2.5e-7,
            thresholdTokens: nil,
            inputCostPerTokenAboveThreshold: nil,
            outputCostPerTokenAboveThreshold: nil,
            cacheCreationInputCostPerTokenAboveThreshold: nil,
            cacheReadInputCostPerTokenAboveThreshold: nil),
        "claude-opus-4-5-20251101": ClaudePricing(
            inputCostPerToken: 5e-6,
            outputCostPerToken: 2.5e-5,
            cacheCreationInputCostPerToken: 6.25e-6,
            cacheReadInputCostPerToken: 5e-7,
            thresholdTokens: nil,
            inputCostPerTokenAboveThreshold: nil,
            outputCostPerTokenAboveThreshold: nil,
            cacheCreationInputCostPerTokenAboveThreshold: nil,
            cacheReadInputCostPerTokenAboveThreshold: nil),
        "claude-opus-4-5": ClaudePricing(
            inputCostPerToken: 5e-6,
            outputCostPerToken: 2.5e-5,
            cacheCreationInputCostPerToken: 6.25e-6,
            cacheReadInputCostPerToken: 5e-7,
            thresholdTokens: nil,
            inputCostPerTokenAboveThreshold: nil,
            outputCostPerTokenAboveThreshold: nil,
            cacheCreationInputCostPerTokenAboveThreshold: nil,
            cacheReadInputCostPerTokenAboveThreshold: nil),
        "claude-opus-4-6-20260205": ClaudePricing(
            inputCostPerToken: 5e-6,
            outputCostPerToken: 2.5e-5,
            cacheCreationInputCostPerToken: 6.25e-6,
            cacheReadInputCostPerToken: 5e-7,
            thresholdTokens: nil,
            inputCostPerTokenAboveThreshold: nil,
            outputCostPerTokenAboveThreshold: nil,
            cacheCreationInputCostPerTokenAboveThreshold: nil,
            cacheReadInputCostPerTokenAboveThreshold: nil),
        "claude-opus-4-6": ClaudePricing(
            inputCostPerToken: 5e-6,
            outputCostPerToken: 2.5e-5,
            cacheCreationInputCostPerToken: 6.25e-6,
            cacheReadInputCostPerToken: 5e-7,
            thresholdTokens: nil,
            inputCostPerTokenAboveThreshold: nil,
            outputCostPerTokenAboveThreshold: nil,
            cacheCreationInputCostPerTokenAboveThreshold: nil,
            cacheReadInputCostPerTokenAboveThreshold: nil),
        "claude-opus-4-7": ClaudePricing(
            inputCostPerToken: 5e-6,
            outputCostPerToken: 2.5e-5,
            cacheCreationInputCostPerToken: 6.25e-6,
            cacheReadInputCostPerToken: 5e-7,
            thresholdTokens: nil,
            inputCostPerTokenAboveThreshold: nil,
            outputCostPerTokenAboveThreshold: nil,
            cacheCreationInputCostPerTokenAboveThreshold: nil,
            cacheReadInputCostPerTokenAboveThreshold: nil),
        "claude-opus-4-8": ClaudePricing(
            inputCostPerToken: 5e-6,
            outputCostPerToken: 2.5e-5,
            cacheCreationInputCostPerToken: 6.25e-6,
            cacheReadInputCostPerToken: 5e-7,
            thresholdTokens: nil,
            inputCostPerTokenAboveThreshold: nil,
            outputCostPerTokenAboveThreshold: nil,
            cacheCreationInputCostPerTokenAboveThreshold: nil,
            cacheReadInputCostPerTokenAboveThreshold: nil),
        "claude-sonnet-4-5": ClaudePricing(
            inputCostPerToken: 3e-6,
            outputCostPerToken: 1.5e-5,
            cacheCreationInputCostPerToken: 3.75e-6,
            cacheReadInputCostPerToken: 3e-7,
            thresholdTokens: 200_000,
            inputCostPerTokenAboveThreshold: 6e-6,
            outputCostPerTokenAboveThreshold: 2.25e-5,
            cacheCreationInputCostPerTokenAboveThreshold: 7.5e-6,
            cacheReadInputCostPerTokenAboveThreshold: 6e-7),
        "claude-sonnet-4-6": ClaudePricing(
            inputCostPerToken: 3e-6,
            outputCostPerToken: 1.5e-5,
            cacheCreationInputCostPerToken: 3.75e-6,
            cacheReadInputCostPerToken: 3e-7,
            thresholdTokens: nil,
            inputCostPerTokenAboveThreshold: nil,
            outputCostPerTokenAboveThreshold: nil,
            cacheCreationInputCostPerTokenAboveThreshold: nil,
            cacheReadInputCostPerTokenAboveThreshold: nil),
        "claude-sonnet-4-5-20250929": ClaudePricing(
            inputCostPerToken: 3e-6,
            outputCostPerToken: 1.5e-5,
            cacheCreationInputCostPerToken: 3.75e-6,
            cacheReadInputCostPerToken: 3e-7,
            thresholdTokens: 200_000,
            inputCostPerTokenAboveThreshold: 6e-6,
            outputCostPerTokenAboveThreshold: 2.25e-5,
            cacheCreationInputCostPerTokenAboveThreshold: 7.5e-6,
            cacheReadInputCostPerTokenAboveThreshold: 6e-7),
        "claude-opus-4-20250514": ClaudePricing(
            inputCostPerToken: 1.5e-5,
            outputCostPerToken: 7.5e-5,
            cacheCreationInputCostPerToken: 1.875e-5,
            cacheReadInputCostPerToken: 1.5e-6,
            thresholdTokens: nil,
            inputCostPerTokenAboveThreshold: nil,
            outputCostPerTokenAboveThreshold: nil,
            cacheCreationInputCostPerTokenAboveThreshold: nil,
            cacheReadInputCostPerTokenAboveThreshold: nil),
        "claude-opus-4-1": ClaudePricing(
            inputCostPerToken: 1.5e-5,
            outputCostPerToken: 7.5e-5,
            cacheCreationInputCostPerToken: 1.875e-5,
            cacheReadInputCostPerToken: 1.5e-6,
            thresholdTokens: nil,
            inputCostPerTokenAboveThreshold: nil,
            outputCostPerTokenAboveThreshold: nil,
            cacheCreationInputCostPerTokenAboveThreshold: nil,
            cacheReadInputCostPerTokenAboveThreshold: nil),
        "claude-sonnet-4-20250514": ClaudePricing(
            inputCostPerToken: 3e-6,
            outputCostPerToken: 1.5e-5,
            cacheCreationInputCostPerToken: 3.75e-6,
            cacheReadInputCostPerToken: 3e-7,
            thresholdTokens: 200_000,
            inputCostPerTokenAboveThreshold: 6e-6,
            outputCostPerTokenAboveThreshold: 2.25e-5,
            cacheCreationInputCostPerTokenAboveThreshold: 7.5e-6,
            cacheReadInputCostPerTokenAboveThreshold: 6e-7),
    ]

    private static let claudeFullContextStandardPricingCutoff = Date(timeIntervalSince1970: 1_773_360_000)
    private static let claudeHistoricalLongContext: [String: ClaudePricing] = [
        "claude-opus-4-6": ClaudePricing(
            inputCostPerToken: 5e-6,
            outputCostPerToken: 2.5e-5,
            cacheCreationInputCostPerToken: 6.25e-6,
            cacheReadInputCostPerToken: 5e-7,
            thresholdTokens: 200_000,
            inputCostPerTokenAboveThreshold: 1e-5,
            outputCostPerTokenAboveThreshold: 3.75e-5,
            cacheCreationInputCostPerTokenAboveThreshold: 1.25e-5,
            cacheReadInputCostPerTokenAboveThreshold: 1e-6),
        "claude-sonnet-4-6": ClaudePricing(
            inputCostPerToken: 3e-6,
            outputCostPerToken: 1.5e-5,
            cacheCreationInputCostPerToken: 3.75e-6,
            cacheReadInputCostPerToken: 3e-7,
            thresholdTokens: 200_000,
            inputCostPerTokenAboveThreshold: 6e-6,
            outputCostPerTokenAboveThreshold: 2.25e-5,
            cacheCreationInputCostPerTokenAboveThreshold: 7.5e-6,
            cacheReadInputCostPerTokenAboveThreshold: 6e-7),
    ]

    /// Route prefixes Claude-compatible clients emit for non-Anthropic models that have models.dev entries.
    ///
    /// The route prefix is part of the model identity for local usage estimates, so pricing-cache
    /// fingerprints invalidate when any supported route's rates change.
    static let routedModelsDevProviderIDs: Set<String> = [
        "deepseek",
        "kimi-coding",
        "kimi-for-coding",
        "openai",
        "opencode",
        "opencode-free",
        "opencode-go",
    ]
    private static let claudeModelsDevProviderID = "anthropic"

    /// Returns the provider/model identities that may price a `route/model` identifier. Direct lookup and
    /// unknown-price refresh share this mapping so a newly downloaded catalog is checked under the same identity.
    static func routedModelsDevPricingTargets(for rawModel: String) -> [(providerID: String, modelID: String)] {
        let trimmed = rawModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let slash = trimmed.firstIndex(of: "/") else { return [] }
        let routeID = String(trimmed[..<slash]).lowercased()
        let modelID = String(trimmed[trimmed.index(after: slash)...])
        guard !routeID.isEmpty, !modelID.isEmpty,
              self.routedModelsDevProviderIDs.contains(routeID)
        else { return [] }
        return ModelsDevPricingTargetResolver.targets(providerID: routeID, modelID: trimmed)
            .map { ($0.providerID, $0.modelID) }
    }

    static func normalizeClaudeModel(_ raw: String) -> String {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("anthropic.") {
            trimmed = String(trimmed.dropFirst("anthropic.".count))
        }

        if let lastDot = trimmed.lastIndex(of: "."),
           trimmed.contains("claude-")
        {
            let tail = String(trimmed[trimmed.index(after: lastDot)...])
            if tail.hasPrefix("claude-") {
                trimmed = tail
            }
        }

        if let vRange = trimmed.range(of: #"-v\d+:\d+$"#, options: .regularExpression) {
            trimmed.removeSubrange(vRange)
        }

        if let baseRange = trimmed.range(of: #"-\d{8}$"#, options: .regularExpression) {
            let base = String(trimmed[..<baseRange.lowerBound])
            if self.claude[base] != nil {
                return base
            }
        }

        return trimmed
    }

    static func customPricingOverlay(fileURL: URL? = nil) -> CostUsageCustomPricing {
        CostUsageCustomPricing.load(fileURL: fileURL)
    }

    static func claudeCostUSD(
        model: String,
        inputTokens: Int,
        cacheReadInputTokens: Int,
        cacheCreationInputTokens: Int,
        cacheCreationInputTokens1h: Int = 0,
        outputTokens: Int,
        pricingDate: Date? = nil,
        modelsDevCatalog: ModelsDevCatalog? = nil,
        modelsDevCacheRoot: URL? = nil) -> Double?
    {
        let tokens = ClaudeCostTokens(
            input: inputTokens,
            cacheRead: cacheReadInputTokens,
            cacheCreation: cacheCreationInputTokens,
            cacheCreation1h: cacheCreationInputTokens1h,
            output: outputTokens)
        let key = self.normalizeClaudeModel(model)
        return self.claudeCostUSD(normalizedModel: key, tokens: tokens, pricingDate: pricingDate) {
            self.claudeModelsDevLookup(model: model, catalog: modelsDevCatalog, cacheRoot: modelsDevCacheRoot)
        }
    }

    private static func claudeCostUSD(
        normalizedModel key: String,
        tokens: ClaudeCostTokens,
        pricingDate: Date?,
        modelsDevLookup: () -> ModelsDevPricingLookup?) -> Double?
    {
        if let pricingDate,
           let historicalPricing = self.claudeHistoricalLongContext[key],
           let currentPricing = self.claude[key]
        {
            return self.claudeCostUSD(
                pricing: pricingDate < self.claudeFullContextStandardPricingCutoff
                    ? historicalPricing
                    : currentPricing,
                tokens: tokens)
        }
        if let lookup = modelsDevLookup() {
            return self.claudeCostUSD(
                pricing: lookup.pricing,
                tokens: tokens)
        }

        guard let pricing = self.claude[key] else { return nil }
        return self.claudeCostUSD(
            pricing: pricing,
            tokens: tokens)
    }

    private static func claudeCostUSD(
        pricing: ClaudePricing,
        tokens: ClaudeCostTokens) -> Double
    {
        let input = max(0, tokens.input)
        let cacheRead = max(0, tokens.cacheRead)
        let cacheCreationTotal = max(0, tokens.cacheCreation)
        let cacheCreation1h = min(max(0, tokens.cacheCreation1h), cacheCreationTotal)
        let cacheCreation5m = cacheCreationTotal - cacheCreation1h
        let usesLongContextRates = pricing.thresholdTokens.map { threshold in
            // Nonnegative components that overflow necessarily exceed every representable threshold.
            CheckedSum.integers([input, cacheRead, cacheCreationTotal]).map { $0 > threshold } ?? true
        } ?? false
        let inputRate = usesLongContextRates
            ? pricing.inputCostPerTokenAboveThreshold ?? pricing.inputCostPerToken
            : pricing.inputCostPerToken
        let cacheReadRate = usesLongContextRates
            ? pricing.cacheReadInputCostPerTokenAboveThreshold ?? pricing.cacheReadInputCostPerToken
            : pricing.cacheReadInputCostPerToken
        let cacheCreation5mRate = usesLongContextRates
            ? pricing.cacheCreationInputCostPerTokenAboveThreshold ?? pricing.cacheCreationInputCostPerToken
            : pricing.cacheCreationInputCostPerToken
        let outputRate = usesLongContextRates
            ? pricing.outputCostPerTokenAboveThreshold ?? pricing.outputCostPerToken
            : pricing.outputCostPerToken

        return Double(input) * inputRate
            + Double(cacheRead) * cacheReadRate
            + Double(cacheCreation5m) * cacheCreation5mRate
            + Double(cacheCreation1h) * inputRate * 2
            + Double(max(0, tokens.output)) * outputRate
    }

    /// OpenAI models whose published pricing switches the full request to long-context rates above 272K input
    /// tokens (OpenAI pricing page). models.dev does not carry this boundary.
    private static let openAILongContextModels: Set<String> = [
        "gpt-5.4", "gpt-5.4-pro", "gpt-5.5", "gpt-5.5-pro",
        "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna",
        "gpt-6-astra", "gpt-6-sol", "gpt-6-luna", "gpt-6.1-sol",
    ]
    private static let openAILongContextThreshold = 272_000

    static func openAILongContextThreshold(model: String) -> Int? {
        var trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("openai/") {
            trimmed = String(trimmed.dropFirst("openai/".count))
        }
        // OpenAI routes these aliases to Sol and Luna.
        switch trimmed {
        case "gpt-5.6", "gpt-daybreak-blue-latest": trimmed = "gpt-5.6-sol"
        case "gpt-reserve": trimmed = "gpt-5.6-luna"
        default: break
        }
        if !self.openAILongContextModels.contains(trimmed),
           let datedSuffix = trimmed.range(of: #"-\d{4}-\d{2}-\d{2}$"#, options: .regularExpression)
        {
            trimmed = String(trimmed[..<datedSuffix.lowerBound])
        }
        return self.openAILongContextModels.contains(trimmed) ? self.openAILongContextThreshold : nil
    }

    static func claudeCostUSD(pricing: ModelsDevPricingInfo, tokens: ClaudeCostTokens) -> Double {
        // Provider-specific by design: OpenAI's threshold also applies to usage recorded by Claude Code.
        let bundledThreshold = pricing.providerID == "openai"
            ? self.openAILongContextThreshold(model: pricing.modelID)
            : nil
        return self.claudeCostUSD(
            pricing: ClaudePricing(
                inputCostPerToken: pricing.inputCostPerToken,
                outputCostPerToken: pricing.outputCostPerToken,
                cacheCreationInputCostPerToken: pricing.cacheCreationInputCostPerToken ?? pricing.inputCostPerToken,
                cacheReadInputCostPerToken: pricing.cacheReadInputCostPerToken ?? pricing.inputCostPerToken,
                thresholdTokens: bundledThreshold ?? pricing.thresholdTokens,
                inputCostPerTokenAboveThreshold: pricing.inputCostPerTokenAboveThreshold,
                outputCostPerTokenAboveThreshold: pricing.outputCostPerTokenAboveThreshold,
                cacheCreationInputCostPerTokenAboveThreshold: pricing.cacheCreationInputCostPerTokenAboveThreshold,
                cacheReadInputCostPerTokenAboveThreshold: pricing.cacheReadInputCostPerTokenAboveThreshold),
            tokens: tokens)
    }

    static func modelsDevCatalog(now: Date = Date(), cacheRoot: URL? = nil) -> ModelsDevCatalog? {
        ModelsDevCache.load(now: now, cacheRoot: cacheRoot).artifact?.catalog
    }

    private static func modelsDevLookup(
        providerID: String,
        model: String,
        catalog: ModelsDevCatalog?,
        cacheRoot: URL?) -> ModelsDevPricingLookup?
    {
        if let catalog {
            return catalog.pricing(providerID: providerID, modelID: model)
        }

        return ModelsDevPricingPipeline.lookup(
            providerID: providerID,
            modelID: model,
            cacheRoot: cacheRoot)
    }
}

extension CostUsagePricing {
    /// One synchronous Claude scan owns the catalog snapshot and exact-input model memos.
    final class ClaudeResolver {
        static let memoEntryLimit = 1024

        private struct LookupResult {
            let value: ModelsDevPricingLookup?
        }

        private let now: Date
        private let cacheRoot: URL?
        private var catalog: ModelsDevCatalog?
        // String equality folds canonically equivalent Unicode; serialized model spelling must survive.
        private var normalizedModels: [[UInt8]: String] = [:]
        private var lookups: [[UInt8]: LookupResult] = [:]

        init(now: Date, cacheRoot: URL?) {
            self.now = now
            self.cacheRoot = cacheRoot
        }

        init(catalog: ModelsDevCatalog) {
            self.now = Date(timeIntervalSince1970: 0)
            self.cacheRoot = nil
            self.catalog = catalog
        }

        @discardableResult
        func prepareCatalog() -> ModelsDevCatalog {
            if let catalog = self.catalog {
                return catalog
            }
            let catalog = CostUsagePricing.modelsDevCatalog(now: self.now, cacheRoot: self.cacheRoot)
                ?? ModelsDevCatalog(providers: [:])
            self.catalog = catalog
            return catalog
        }

        func normalize(_ model: String) -> String {
            let key = Array(model.utf8)
            if let normalized = self.normalizedModels[key] {
                return normalized
            }
            #if DEBUG
            CostUsageScanner.recordClaudeScanWork(.normalizationCacheMiss)
            #endif
            let normalized = CostUsagePricing.normalizeClaudeModel(model)
            if self.normalizedModels.count < Self.memoEntryLimit {
                self.normalizedModels[key] = normalized
            }
            return normalized
        }

        private func lookup(_ model: String) -> ModelsDevPricingLookup? {
            let key = Array(model.utf8)
            if let result = self.lookups[key] {
                return result.value
            }
            let value = CostUsagePricing.claudeModelsDevLookup(
                model: model, catalog: self.prepareCatalog(), cacheRoot: nil)
            #if DEBUG
            CostUsageScanner.recordClaudeScanWork(.catalogModelLookup(found: value != nil))
            #endif
            if self.lookups.count < Self.memoEntryLimit {
                self.lookups[key] = LookupResult(value: value)
            }
            return value
        }

        func costUSD(
            model: String,
            providerID: String? = nil,
            inputTokens: Int,
            cacheReadInputTokens: Int,
            cacheCreationInputTokens: Int,
            cacheCreationInputTokens1h: Int = 0,
            outputTokens: Int,
            pricingDate: Date? = nil) -> Double?
        {
            let tokens = ClaudeCostTokens(
                input: inputTokens,
                cacheRead: cacheReadInputTokens,
                cacheCreation: cacheCreationInputTokens,
                cacheCreation1h: cacheCreationInputTokens1h,
                output: outputTokens)
            // Explicit provider routes stay in this catalog snapshot and never borrow another vendor's price.
            if let providerID {
                guard let lookup = self.prepareCatalog().pricing(providerID: providerID, modelID: model)
                else { return nil }
                return CostUsagePricing.claudeCostUSD(pricing: lookup.pricing, tokens: tokens)
            }
            let key = self.normalize(model)
            return CostUsagePricing.claudeCostUSD(normalizedModel: key, tokens: tokens, pricingDate: pricingDate) {
                self.lookup(model)
            }
        }
    }

    /// Bare Claude-routed IDs may match first-party models.dev vendors. Recognizable model families
    /// stay with their vendor, while unknown bare IDs must have one unambiguous catalog match.
    /// Provider-specific by design: first-party vendor routing for bare Claude model IDs.
    static let claudeFirstPartyModelsDevProviderIDs: [String] = [
        Self.claudeModelsDevProviderID,
        "openai",
        "google",
        "moonshot",
        "kimi-for-coding",
        "minimax",
        "deepseek",
    ]

    static func claudeModelsDevPricingTargets(for rawModel: String) -> [(providerID: String, modelID: String)] {
        var targets = self.claudeUnaliasedModelsDevPricingTargets(for: rawModel)
        // Claude's documented context-window alias stays inside Kimi Code, after every exact route match.
        if targets.contains(where: {
            $0.providerID == "kimi-for-coding"
                && $0.modelID.trimmingCharacters(in: .whitespacesAndNewlines) == "k3[1m]"
        }) {
            targets.append(("kimi-for-coding", "k3"))
        }
        return targets
    }

    private static func claudeUnaliasedModelsDevPricingTargets(
        for rawModel: String) -> [(providerID: String, modelID: String)]
    {
        let trimmed = rawModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        if let slash = trimmed.firstIndex(of: "/") {
            let routedTargets = self.routedModelsDevPricingTargets(for: trimmed)
            if !routedTargets.isEmpty {
                return routedTargets
            }

            let routeID = String(trimmed[..<slash]).lowercased()
            let modelID = String(trimmed[trimmed.index(after: slash)...])
            guard !routeID.isEmpty, !modelID.isEmpty,
                  self.claudeFirstPartyModelsDevProviderIDs.contains(routeID)
            else { return [] }
            return self.claudeModelsDevModelIDs(for: modelID).map { (routeID, $0) }
        }

        let providerIDs = self.claudeFirstPartyModelsDevPreferredProviderIDs(for: trimmed)
            ?? self.claudeFirstPartyModelsDevProviderIDs
        let modelIDs = self.claudeModelsDevModelIDs(for: trimmed)
        return providerIDs.flatMap { providerID in
            modelIDs.map { (providerID, $0) }
        }
    }

    private static func claudeModelsDevModelIDs(for rawModel: String) -> [String] {
        let normalized = self.normalizeClaudeModel(rawModel)
        return normalized == rawModel ? [rawModel] : [rawModel, normalized]
    }

    private static func claudeFirstPartyModelsDevPreferredProviderIDs(for rawModel: String) -> [String]? {
        let model = self.normalizeClaudeModel(rawModel).lowercased()
        if model.hasPrefix("claude-") {
            return [self.claudeModelsDevProviderID]
        }
        let openAIReasoningFamily = ["o1", "o3", "o4"].contains {
            model == $0 || model.hasPrefix("\($0)-")
        }
        if openAIReasoningFamily
            || ["gpt-", "chatgpt-", "text-embedding-"].contains(where: model.hasPrefix)
        {
            // Provider-specific by design: recognizable model families stay in their owning first-party catalog.
            return ["openai"]
        }
        if ["gemini-", "gemma-", "deep-research-", "veo-", "lyria-"].contains(where: model.hasPrefix) {
            return ["google"]
        }
        if model == "kimi-for-coding" || model == "k3" || model == "k3[1m]" || model.hasPrefix("k3-") {
            return ["kimi-for-coding"]
        }
        if model.hasPrefix("kimi-") || model.hasPrefix("moonshot-") {
            return ["moonshot", "kimi-for-coding"]
        }
        if model.hasPrefix("minimax-") {
            return ["minimax"]
        }
        if model.hasPrefix("deepseek-") {
            return ["deepseek"]
        }
        return nil
    }

    fileprivate static func claudeModelsDevLookup(
        model rawModel: String,
        catalog: ModelsDevCatalog?,
        cacheRoot: URL?) -> ModelsDevPricingLookup?
    {
        let trimmed = rawModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasExplicitRoute = trimmed.contains("/")
        let hasPreferredVendor = self.claudeFirstPartyModelsDevPreferredProviderIDs(for: trimmed) != nil
        var matches: [ModelsDevPricingLookup] = []
        for target in self.claudeModelsDevPricingTargets(for: rawModel) {
            if let lookup = self.modelsDevLookup(
                providerID: target.providerID,
                model: target.modelID,
                catalog: catalog,
                cacheRoot: cacheRoot)
            {
                if hasExplicitRoute || hasPreferredVendor {
                    return lookup
                }
                matches.append(lookup)
            }
        }
        let matchedProviderIDs = Set(matches.map(\.pricing.providerID))
        guard matchedProviderIDs.count == 1 else { return nil }
        return matches.first
    }
}
