import Foundation

public struct RateWindow: Codable, Equatable, Sendable {
    /// Provider usage value, intentionally not normalized globally. Pace and provider-specific diagnostics may
    /// preserve raw over-quota values; display-only projections should use `UsagePercent.displayClamped`.
    public let usedPercent: Double
    /// Optional provider-supplied label for generic usage-window presentation.
    public let title: String?
    public let windowMinutes: Int?
    public let resetsAt: Date?
    /// Optional textual reset description (used by Claude CLI UI scrape).
    public let resetDescription: String?
    /// Absolute allowance and its unit, when reported alongside the percentage.
    public let quotaLimit: Double?
    public let quotaUnit: String?
    /// Optional percent restored on the next regeneration tick for providers with rolling recovery.
    public let nextRegenPercent: Double?
    /// Whether this window was synthesized to stand in for a quota lane the provider did not actually
    /// report, rather than being a real zero-usage window.
    ///
    /// Claude web returns a `0%` five-hour window when `five_hour` is `null` (an account with no live
    /// session but a real weekly lane). Lane classifiers — e.g. the combined "Session + Weekly" menu-bar
    /// metric — must treat such a window as "no session lane present" instead of surfacing a phantom
    /// `5h 0%`/`5h 100%` session. A genuine session, even one freshly reset to 0%, is NOT a placeholder.
    /// Missing values decode as `false` for older cached payloads.
    public let isSyntheticPlaceholder: Bool

    public init(
        usedPercent: Double,
        windowMinutes: Int?,
        resetsAt: Date?,
        resetDescription: String?,
        quotaLimit: Double? = nil,
        quotaUnit: String? = nil,
        nextRegenPercent: Double? = nil,
        isSyntheticPlaceholder: Bool = false,
        title: String? = nil)
    {
        self.usedPercent = usedPercent
        self.title = title
        self.windowMinutes = windowMinutes
        self.resetsAt = resetsAt
        self.resetDescription = resetDescription
        self.quotaLimit = quotaLimit
        self.quotaUnit = quotaUnit
        self.nextRegenPercent = nextRegenPercent
        self.isSyntheticPlaceholder = isSyntheticPlaceholder
    }

    private enum CodingKeys: String, CodingKey {
        case usedPercent
        case title
        case windowMinutes
        case resetsAt
        case resetDescription
        case quotaLimit
        case quotaUnit
        case nextRegenPercent
        case isSyntheticPlaceholder
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.usedPercent = try container.decode(Double.self, forKey: .usedPercent)
        self.title = try container.decodeIfPresent(String.self, forKey: .title)
        self.windowMinutes = try container.decodeIfPresent(Int.self, forKey: .windowMinutes)
        self.resetsAt = try container.decodeIfPresent(Date.self, forKey: .resetsAt)
        self.resetDescription = try container.decodeIfPresent(String.self, forKey: .resetDescription)
        self.quotaLimit = try container.decodeIfPresent(Double.self, forKey: .quotaLimit)
        self.quotaUnit = try container.decodeIfPresent(String.self, forKey: .quotaUnit)
        self.nextRegenPercent = try container.decodeIfPresent(Double.self, forKey: .nextRegenPercent)
        self.isSyntheticPlaceholder =
            try container.decodeIfPresent(Bool.self, forKey: .isSyntheticPlaceholder) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.usedPercent, forKey: .usedPercent)
        try container.encodeIfPresent(self.title, forKey: .title)
        try container.encodeIfPresent(self.windowMinutes, forKey: .windowMinutes)
        try container.encodeIfPresent(self.resetsAt, forKey: .resetsAt)
        try container.encodeIfPresent(self.resetDescription, forKey: .resetDescription)
        try container.encodeIfPresent(self.quotaLimit, forKey: .quotaLimit)
        try container.encodeIfPresent(self.quotaUnit, forKey: .quotaUnit)
        try container.encodeIfPresent(self.nextRegenPercent, forKey: .nextRegenPercent)
        // Only persist the flag when set, keeping payloads identical for the common (real-window) case.
        if self.isSyntheticPlaceholder {
            try container.encode(true, forKey: .isSyntheticPlaceholder)
        }
    }

    /// A synthetic placeholder has no measured quota value, even when its stored percent is zero.
    public var measured: Self? {
        self.isSyntheticPlaceholder ? nil : self
    }

    public var remainingPercent: Double {
        max(0, 100 - self.usedPercent)
    }

    public func backfillingResetTime(from cached: RateWindow?, now: Date = .init()) -> RateWindow {
        if self.resetsAt != nil {
            return self
        }
        guard let cachedReset = cached?.resetsAt, cachedReset > now else { return self }
        let windowMinutes = if let windowMinutes = self.windowMinutes, windowMinutes > 0 {
            windowMinutes
        } else {
            cached?.windowMinutes
        }
        return RateWindow(
            usedPercent: self.usedPercent,
            windowMinutes: windowMinutes,
            resetsAt: cachedReset,
            resetDescription: self.resetDescription ?? cached?.resetDescription,
            quotaLimit: self.quotaLimit,
            quotaUnit: self.quotaUnit,
            nextRegenPercent: self.nextRegenPercent,
            // Preserve the placeholder marker: backfilling a stale reset onto Claude web's null-session
            // placeholder must not let it masquerade as a real session lane.
            isSyntheticPlaceholder: self.isSyntheticPlaceholder,
            title: self.title)
    }
}

public struct NamedRateWindow: Codable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let window: RateWindow
    /// Whether `window.usedPercent` reflects known quota usage.
    ///
    /// Some providers expose reset metadata for a named quota window before
    /// they expose remaining usage. Keep those windows visible for reset/debug
    /// context, but mark them so clients do not render `usedPercent` as a real
    /// exhausted quota. Missing values decode as `true` for older cached payloads.
    public let usageKnown: Bool

    public init(id: String, title: String, window: RateWindow, usageKnown: Bool = true) {
        self.id = id
        self.title = title
        self.window = window
        self.usageKnown = usageKnown
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case window
        case usageKnown
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.title = try container.decode(String.self, forKey: .title)
        self.window = try container.decode(RateWindow.self, forKey: .window)
        self.usageKnown = try container.decodeIfPresent(Bool.self, forKey: .usageKnown) ?? true
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.id, forKey: .id)
        try container.encode(self.title, forKey: .title)
        try container.encode(self.window, forKey: .window)
        if !self.usageKnown {
            try container.encode(false, forKey: .usageKnown)
        }
    }
}

public struct UsageSnapshot: Codable, Sendable {
    public let primary: RateWindow?
    public let secondary: RateWindow?
    public let tertiary: RateWindow?
    public let extraRateWindows: [NamedRateWindow]?
    public let providerCost: ProviderCostSnapshot?
    /// Live provider-reported cost history supplied through the generic plugin contract.
    public let costUsage: CostUsageTokenSnapshot?
    public let details: [ProviderDetailSection]
    public let deepseekDetailedUsageState: DeepSeekDetailedUsageState
    public let deepseekPlatformProfiles: [DeepSeekPlatformProfile]
    /// Live-only ownership proof; decoded usage cannot authorize browser balance retention.
    public let deepseekPlatformBalanceOwner: DeepSeekPlatformBalanceOwner?
    /// Live-only ownership proof; a profile directory alone does not identify an account.
    public let browserSessionOwner: ProviderBrowserSessionOwner?
    public let opencodegoUsage: OpenCodeGoUsageSnapshot?
    public let throughput: ProviderThroughputSnapshot?
    /// Live-only display inventory. Claude grant identifiers are never decoded.
    public let claudeResetCredits: ClaudeRateLimitResetCreditsSnapshot?
    public let subscriptionExpiresAt: Date?
    public let subscriptionRenewsAt: Date?
    public let subscriptionRenewsAtIsDateOnly: Bool
    public let subscriptionExpiresAtIsDateOnly: Bool
    public let updatedAt: Date
    public let identity: ProviderIdentitySnapshot?
    public let dataConfidence: UsageDataConfidence

    private enum CodingKeys: String, CodingKey {
        case primary
        case secondary
        case tertiary
        case extraRateWindows
        case providerCost
        case details
        case throughput
        case subscriptionExpiresAt
        case subscriptionRenewsAt
        case subscriptionRenewsAtIsDateOnly
        case subscriptionExpiresAtIsDateOnly
        case updatedAt
        case identity
        case dataConfidence
        case accountEmail
        case accountOrganization
        case loginMethod
    }

    public init(
        primary: RateWindow?,
        secondary: RateWindow?,
        tertiary: RateWindow? = nil,
        extraRateWindows: [NamedRateWindow]? = nil,
        providerCost: ProviderCostSnapshot? = nil,
        costUsage: CostUsageTokenSnapshot? = nil,
        details: [ProviderDetailSection] = [],
        deepseekDetailedUsageState: DeepSeekDetailedUsageState = .notRequested,
        deepseekPlatformProfiles: [DeepSeekPlatformProfile] = [],
        deepseekPlatformBalanceOwner: DeepSeekPlatformBalanceOwner? = nil,
        browserSessionOwner: ProviderBrowserSessionOwner? = nil,
        opencodegoUsage: OpenCodeGoUsageSnapshot? = nil,
        throughput: ProviderThroughputSnapshot? = nil,
        claudeResetCredits: ClaudeRateLimitResetCreditsSnapshot? = nil,
        subscriptionExpiresAt: Date? = nil,
        subscriptionRenewsAt: Date? = nil,
        subscriptionRenewsAtIsDateOnly: Bool = false,
        subscriptionExpiresAtIsDateOnly: Bool = false,
        updatedAt: Date,
        identity: ProviderIdentitySnapshot? = nil,
        dataConfidence: UsageDataConfidence = .unknown)
    {
        precondition(
            details.count <= ProviderDetailSection.maximumSectionsPerSnapshot,
            "UsageSnapshot details exceeds \(ProviderDetailSection.maximumSectionsPerSnapshot) sections")
        self.primary = primary
        self.secondary = secondary
        self.tertiary = tertiary
        self.extraRateWindows = extraRateWindows
        self.providerCost = providerCost
        self.costUsage = costUsage
        self.details = details
        self.deepseekDetailedUsageState = deepseekDetailedUsageState
        self.deepseekPlatformProfiles = deepseekPlatformProfiles
        self.deepseekPlatformBalanceOwner = deepseekPlatformBalanceOwner
        self.browserSessionOwner = browserSessionOwner
        self.opencodegoUsage = opencodegoUsage
        self.throughput = throughput
        self.claudeResetCredits = claudeResetCredits
        self.subscriptionExpiresAt = subscriptionExpiresAt
        self.subscriptionRenewsAt = subscriptionRenewsAt
        self.subscriptionRenewsAtIsDateOnly = subscriptionRenewsAtIsDateOnly
        self.subscriptionExpiresAtIsDateOnly = subscriptionExpiresAtIsDateOnly
        self.updatedAt = updatedAt
        self.identity = identity
        self.dataConfidence = dataConfidence
    }

    public func with(extraRateWindows: [NamedRateWindow]?) -> UsageSnapshot {
        self.replacing(extraRateWindows: .value(extraRateWindows))
    }

    public func with(details: [ProviderDetailSection]) -> UsageSnapshot {
        self.replacing(details: .value(details))
    }

    public func withSubscriptionMetadata(
        expiresAt: Date?,
        renewsAt: Date?,
        expiresAtIsDateOnly: Bool = false,
        renewsAtIsDateOnly: Bool = false) -> UsageSnapshot
    {
        self.replacing(
            subscriptionExpiresAt: .value(expiresAt),
            subscriptionRenewsAt: .value(renewsAt),
            subscriptionRenewsAtIsDateOnly: .value(renewsAtIsDateOnly),
            subscriptionExpiresAtIsDateOnly: .value(expiresAtIsDateOnly))
    }

    public func with(primary: RateWindow?, secondary: RateWindow?) -> UsageSnapshot {
        self.replacing(
            primary: .value(primary),
            secondary: .value(secondary))
    }

    public func with(tertiary: RateWindow?) -> UsageSnapshot {
        self.replacing(tertiary: .value(tertiary))
    }

    public func with(providerCost: ProviderCostSnapshot?) -> UsageSnapshot {
        self.replacing(providerCost: .value(providerCost))
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedIdentity: ProviderIdentitySnapshot?
        if let identity = try container.decodeIfPresent(ProviderIdentitySnapshot.self, forKey: .identity) {
            decodedIdentity = identity
        } else {
            let email = try container.decodeIfPresent(String.self, forKey: .accountEmail)
            let organization = try container.decodeIfPresent(String.self, forKey: .accountOrganization)
            let loginMethod = try container.decodeIfPresent(String.self, forKey: .loginMethod)
            if email != nil || organization != nil || loginMethod != nil {
                decodedIdentity = ProviderIdentitySnapshot(
                    providerID: nil,
                    accountEmail: email,
                    accountOrganization: organization,
                    loginMethod: loginMethod)
            } else {
                decodedIdentity = nil
            }
        }
        self.primary = try container.decodeIfPresent(RateWindow.self, forKey: .primary)
        self.secondary = try container.decodeIfPresent(RateWindow.self, forKey: .secondary)
        self.tertiary = try container.decodeIfPresent(RateWindow.self, forKey: .tertiary)
        self.extraRateWindows = try container.decodeIfPresent([NamedRateWindow].self, forKey: .extraRateWindows)
        self.providerCost = try container.decodeIfPresent(ProviderCostSnapshot.self, forKey: .providerCost)
        self.costUsage = nil // Live-only provider history; refresh from the authoritative source.
        let details = try container.decodeIfPresent([ProviderDetailSection].self, forKey: .details) ?? []
        try ProviderDetailSection.validateSections(details)
        // Provider-specific by design: native Claude reset-credit rows are live-only inventory.
        self.details = decodedIdentity?.providerID == .claude
            ? Self.removingLiveResetCreditDetails(from: details)
            : details
        self.deepseekDetailedUsageState = .notRequested // Live-only fetch state
        self.deepseekPlatformProfiles = [] // Live-only browser profile catalog
        self.deepseekPlatformBalanceOwner = nil // Live-only balance ownership
        self.browserSessionOwner = nil // Live-only browser session ownership
        self.opencodegoUsage = nil // Not persisted, fetched fresh each time
        self.throughput = try container.decodeIfPresent(ProviderThroughputSnapshot.self, forKey: .throughput)
        self.claudeResetCredits = nil // Live-only inventory; a reset used on claude.ai must not reappear.
        self.subscriptionExpiresAt = try container.decodeIfPresent(Date.self, forKey: .subscriptionExpiresAt)
        self.subscriptionRenewsAt = try container.decodeIfPresent(Date.self, forKey: .subscriptionRenewsAt)
        self.subscriptionRenewsAtIsDateOnly = try container.decodeIfPresent(
            Bool.self,
            forKey: .subscriptionRenewsAtIsDateOnly) ?? false
        self.subscriptionExpiresAtIsDateOnly = try container.decodeIfPresent(
            Bool.self,
            forKey: .subscriptionExpiresAtIsDateOnly) ?? false
        self.updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        if let dataConfidence = try container.decodeIfPresent(String.self, forKey: .dataConfidence) {
            self.dataConfidence = UsageDataConfidence(rawValue: dataConfidence) ?? .unknown
        } else {
            self.dataConfidence = .unknown
        }
        self.identity = decodedIdentity
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        // Stable JSON schema: keep window keys present (encode `nil` as `null`).
        try container.encode(self.primary, forKey: .primary)
        try container.encode(self.secondary, forKey: .secondary)
        try container.encode(self.tertiary, forKey: .tertiary)
        try container.encodeIfPresent(self.extraRateWindows, forKey: .extraRateWindows)
        try container.encodeIfPresent(self.providerCost, forKey: .providerCost)
        if !self.details.isEmpty {
            try container.encode(self.details, forKey: .details)
        }
        try container.encodeIfPresent(self.throughput, forKey: .throughput)
        try container.encodeIfPresent(self.subscriptionRenewsAt, forKey: .subscriptionRenewsAt)
        if self.subscriptionRenewsAtIsDateOnly { try container.encode(true, forKey: .subscriptionRenewsAtIsDateOnly) }
        if self.subscriptionExpiresAtIsDateOnly { try container.encode(true, forKey: .subscriptionExpiresAtIsDateOnly) }
        try container.encode(self.updatedAt, forKey: .updatedAt)
        try container.encodeIfPresent(self.identity, forKey: .identity)
        if self.dataConfidence != .unknown {
            try container.encode(self.dataConfidence, forKey: .dataConfidence)
        }
        try container.encodeIfPresent(self.identity?.accountEmail, forKey: .accountEmail)
        try container.encodeIfPresent(self.identity?.accountOrganization, forKey: .accountOrganization)
        try container.encodeIfPresent(self.identity?.loginMethod, forKey: .loginMethod)
    }

    public func identity(for instanceID: ProviderInstanceID) -> ProviderIdentitySnapshot? {
        guard let identity, identity.providerID == instanceID else { return nil }
        return identity
    }

    public func accountEmail(for provider: UsageProvider) -> String? {
        self.identity(for: provider.instanceID)?.accountEmail
    }

    public func accountOrganization(for provider: UsageProvider) -> String? {
        self.identity(for: provider.instanceID)?.accountOrganization
    }

    public func loginMethod(for provider: UsageProvider) -> String? {
        self.identity(for: provider.instanceID)?.loginMethod
    }

    public var hasRateLimitWindows: Bool {
        self.primary != nil || self.secondary != nil || self.tertiary != nil ||
            !(self.extraRateWindows?.isEmpty ?? true)
    }

    public var measuredRateWindows: [RateWindow] {
        let windows = [self.primary, self.secondary, self.tertiary]
            + (self.extraRateWindows ?? []).filter(\.usageKnown).map(\.window)
        return windows.compactMap { $0?.measured }
    }

    public func detailRow(label: String) -> ProviderDetailSection.Row? {
        self.details.lazy.flatMap(\.rows).first { $0.label == label }
    }

    public func detailRow(id: String) -> ProviderDetailSection.Row? {
        self.details.lazy.flatMap(\.rows).first { $0.id == id }
    }

    public func rateLimitsUnavailable(for provider: UsageProvider) -> Bool {
        UsageLimitsAvailability.resolve(provider: provider, snapshot: self).isUnavailable
    }

    public func withIdentity(_ identity: ProviderIdentitySnapshot?) -> UsageSnapshot {
        self.replacing(identity: .value(identity))
    }

    public func withDataConfidence(_ dataConfidence: UsageDataConfidence) -> UsageSnapshot {
        self.replacing(dataConfidence: .value(dataConfidence))
    }

    public func scoped(to provider: UsageProvider) -> UsageSnapshot {
        guard let identity else { return self }
        let scopedIdentity = identity.scoped(to: provider)
        if scopedIdentity.providerID == identity.providerID {
            return self
        }
        return self.withIdentity(scopedIdentity)
    }

    private static func removingLiveResetCreditDetails(
        from details: [ProviderDetailSection]) -> [ProviderDetailSection]
    {
        details.compactMap { section -> ProviderDetailSection? in
            let rows = section.rows.filter { $0.label != ClaudeRateLimitResetCreditsSnapshot.detailLabel }
            guard !rows.isEmpty || section.chart != nil else { return nil }
            return .makeSection(title: section.title, rows: rows, chart: section.chart)
        }
    }

    public func backfillingResetTimes(from cached: UsageSnapshot?, now: Date = .init()) -> UsageSnapshot {
        guard let cached else { return self }
        guard Self.identitiesMatch(self.identity, cached.identity) else { return self }
        let cachedPrimary = cached.primary
        let primary = self.primary?.backfillingResetTime(
            from: cachedPrimary, now: now)
        let secondary = self.secondary?.backfillingResetTime(
            from: cached.secondary, now: now)
        let tertiary = self.tertiary?.backfillingResetTime(
            from: cached.tertiary, now: now)
        if primary == self.primary, secondary == self.secondary, tertiary == self.tertiary {
            return self
        }
        return self.replacing(
            primary: .value(primary),
            secondary: .value(secondary),
            tertiary: .value(tertiary))
    }

    private static func identitiesMatch(_ lhs: ProviderIdentitySnapshot?, _ rhs: ProviderIdentitySnapshot?) -> Bool {
        if lhs == nil, rhs == nil {
            return true
        }
        guard let lhs, let rhs else { return false }
        let lhsAccountID = lhs.accountID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let rhsAccountID = rhs.accountID?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let lhsAccountID, let rhsAccountID, !lhsAccountID.isEmpty, !rhsAccountID.isEmpty {
            return lhsAccountID == rhsAccountID
        }
        let lhsEmail = lhs.accountEmail?.trimmingCharacters(in: .whitespacesAndNewlines)
        let rhsEmail = rhs.accountEmail?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let lhsEmail, let rhsEmail, !lhsEmail.isEmpty, !rhsEmail.isEmpty {
            return lhsEmail == rhsEmail
        }
        return true
    }

    package enum Replacement<Value> {
        case unchanged
        case value(Value)

        func resolving(_ current: Value) -> Value {
            switch self {
            case .unchanged: current
            case let .value(value): value
            }
        }
    }

    package func replacing(
        primary: Replacement<RateWindow?> = .unchanged,
        secondary: Replacement<RateWindow?> = .unchanged,
        tertiary: Replacement<RateWindow?> = .unchanged,
        extraRateWindows: Replacement<[NamedRateWindow]?> = .unchanged,
        providerCost: Replacement<ProviderCostSnapshot?> = .unchanged,
        costUsage: Replacement<CostUsageTokenSnapshot?> = .unchanged,
        details: Replacement<[ProviderDetailSection]> = .unchanged,
        deepseekDetailedUsageState: Replacement<DeepSeekDetailedUsageState> = .unchanged,
        deepseekPlatformProfiles: Replacement<[DeepSeekPlatformProfile]> = .unchanged,
        browserSessionOwner: Replacement<ProviderBrowserSessionOwner?> = .unchanged,
        subscriptionExpiresAt: Replacement<Date?> = .unchanged,
        subscriptionRenewsAt: Replacement<Date?> = .unchanged,
        subscriptionRenewsAtIsDateOnly: Replacement<Bool> = .unchanged,
        subscriptionExpiresAtIsDateOnly: Replacement<Bool> = .unchanged,
        identity: Replacement<ProviderIdentitySnapshot?> = .unchanged,
        dataConfidence: Replacement<UsageDataConfidence> = .unchanged) -> UsageSnapshot
    {
        UsageSnapshot(
            primary: primary.resolving(self.primary),
            secondary: secondary.resolving(self.secondary),
            tertiary: tertiary.resolving(self.tertiary),
            extraRateWindows: extraRateWindows.resolving(self.extraRateWindows),
            providerCost: providerCost.resolving(self.providerCost),
            costUsage: costUsage.resolving(self.costUsage),
            details: details.resolving(self.details),
            deepseekDetailedUsageState: deepseekDetailedUsageState.resolving(self.deepseekDetailedUsageState),
            deepseekPlatformProfiles: deepseekPlatformProfiles.resolving(self.deepseekPlatformProfiles),
            deepseekPlatformBalanceOwner: self.deepseekPlatformBalanceOwner,
            browserSessionOwner: browserSessionOwner.resolving(self.browserSessionOwner),
            opencodegoUsage: self.opencodegoUsage,
            throughput: self.throughput,
            claudeResetCredits: self.claudeResetCredits,
            subscriptionExpiresAt: subscriptionExpiresAt.resolving(self.subscriptionExpiresAt),
            subscriptionRenewsAt: subscriptionRenewsAt.resolving(self.subscriptionRenewsAt),
            subscriptionRenewsAtIsDateOnly: subscriptionRenewsAtIsDateOnly
                .resolving(self.subscriptionRenewsAtIsDateOnly),
            subscriptionExpiresAtIsDateOnly: subscriptionExpiresAtIsDateOnly
                .resolving(self.subscriptionExpiresAtIsDateOnly),
            updatedAt: self.updatedAt,
            identity: identity.resolving(self.identity),
            dataConfidence: dataConfidence.resolving(self.dataConfidence))
    }
}

public enum UsageLimitsAvailability: Equatable, Sendable {
    case available
    case unavailable

    public var isUnavailable: Bool {
        self == .unavailable
    }

    public static func resolve(
        provider: UsageProvider,
        snapshot: UsageSnapshot?,
        lastErrorDescription: String? = nil) -> Self
    {
        // Provider-specific by design: Claude error text signals whether a successful payload actually contains
        // subscription limits.
        if provider == .claude {
            if let snapshot {
                return snapshot.measuredRateWindows.isEmpty
                    && (snapshot.primary?.isSyntheticPlaceholder == true || snapshot.providerCost == nil)
                    ? .unavailable : .available
            }
            return ClaudeStatusProbe.isSubscriptionQuotaUnavailableDescription(lastErrorDescription)
                ? .unavailable
                : .available
        }

        return .available
    }
}
