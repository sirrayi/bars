import BarsCore
import SwiftUI

extension UsageMenuCardView.Model {
    /// Resolves the displayed primary percentage/reset through the provider's binding quotas.
    /// Primary-owned detail text remains sourced from the raw primary window.
    static func bindingQuotaProjection(
        input: Input,
        primary: RateWindow,
        snapshot: UsageSnapshot) -> RateWindowBindingQuotaProjection?
    {
        let lanes = ProviderDescriptorRegistry.descriptor(for: input.provider)
            .presentation.primaryBindingQuotaLanes
        let bindingWindows = lanes.compactMap { lane -> RateWindow? in
            switch lane {
            case .primary: nil
            case .secondary: snapshot.secondary
            case .tertiary: snapshot.tertiary
            }
        }
        guard !bindingWindows.isEmpty else { return nil }
        return RateWindow.bindingQuotaProjection(
            primary: primary,
            bindingLanes: bindingWindows,
            now: input.now)
    }

    struct PaceDetail {
        let leftLabel: String
        let rightLabel: String?
        let pacePercent: Double?
        let paceOnTop: Bool
        /// True only for text produced by a pace calculation. Defaults to false
        /// so provider-owned text sharing the detail slot is preserved.
        let isPaceDerived: Bool

        init(
            leftLabel: String,
            rightLabel: String?,
            pacePercent: Double?,
            paceOnTop: Bool,
            isPaceDerived: Bool = false)
        {
            self.leftLabel = leftLabel
            self.rightLabel = rightLabel
            self.pacePercent = pacePercent
            self.paceOnTop = paceOnTop
            self.isPaceDerived = isPaceDerived
        }
    }

    struct PrimaryMetricPresentation {
        var statusText: String?
        var resetText: String?
        var detailText: String?
        var detailLeft: String?
        var detailRight: String?
        var pacePercent: Double?
        var paceOnTop = true
        var detailIsPaceDerived = false
    }

    static func applyPrimaryQuotaPresentation(
        _ presentation: inout PrimaryMetricPresentation,
        input: Input,
        primary: RateWindow)
    {
        let policy = ProviderDescriptorRegistry.descriptor(for: input.provider).presentation.menuCard
        guard let detail = self.trimmedResetDescription(primary) else { return }
        switch policy.primaryDescriptionPlacement {
        case .reset:
            presentation.resetText = detail
        case .detailLeft:
            presentation.detailLeft = detail
        case .detail:
            presentation.detailText = detail
        case .standard:
            break
        }
    }

    static func applyPrimaryBalancePresentation(
        _ presentation: inout PrimaryMetricPresentation,
        input: Input,
        primary: RateWindow)
    {
        let policy = ProviderDescriptorRegistry.descriptor(for: input.provider).presentation.menuCard
        if policy.showsPrimaryBalanceDescription,
           let detail = nonEmptyResetDescription(primary)
        {
            presentation.detailText = detail
        }
        switch policy.primaryDetailKind {
        case .poeBalance, .kiroCredits, .none, .requestQuota:
            break
        }
        if policy.clearsPrimaryReset {
            presentation.resetText = nil
        }
    }

    static func applyPrimaryResetPresentation(
        _ presentation: inout PrimaryMetricPresentation,
        input: Input,
        primary: RateWindow)
    {
        let policy = ProviderDescriptorRegistry.descriptor(for: input.provider).presentation.menuCard
        if policy.usesRawPrimaryResetDescription {
            presentation.resetText = primary.resetDescription
        }
        if policy.hidesPrimaryResetWithoutDate, primary.resetsAt == nil {
            presentation.resetText = nil
        }
    }

    static func applyPrimaryPacePresentation(
        _ presentation: inout PrimaryMetricPresentation,
        input: Input,
        primary: RateWindow)
    {
        let policy = ProviderDescriptorRegistry.descriptor(for: input.provider).presentation.menuCard
        if let paceDetail = sessionPaceDetail(
            provider: input.provider,
            window: primary,
            now: input.now,
            showUsed: input.usageBarsShowUsed)
        {
            self.apply(paceDetail, to: &presentation)
        }
        if policy.usesAbacusPace {
            if let detail = Self.nonEmptyResetDescription(primary) {
                presentation.detailText = detail
            }
            if primary.resetsAt == nil {
                presentation.resetText = nil
            }
            if let pace = input.weeklyPace,
               let paceDetail = Self.weeklyPaceDetail(
                   provider: input.provider,
                   window: primary,
                   now: input.now,
                   pace: pace,
                   showUsed: input.usageBarsShowUsed)
            {
                Self.apply(paceDetail, to: &presentation)
            }
        } else if let paceDetail = Self.resetWindowPaceDetail(
            window: primary,
            input: input,
            pace: policy.resetWindowUsesWeeklyPace ? input.weeklyPace : nil)
        {
            Self.apply(paceDetail, to: &presentation)
        }
    }

    static func applyPrimaryFinalOverrides(
        _ presentation: inout PrimaryMetricPresentation,
        input: Input,
        primary: RateWindow)
    {
        let policy = ProviderDescriptorRegistry.descriptor(for: input.provider).presentation.menuCard
        // Legacy request-based Cursor plans surface the raw used/limit quota on its own line.
        if case .requestQuota = policy.primaryDetailKind,
           let quota = input.snapshot?.detailRow(label: "Request quota")?.value
        {
            presentation.detailText = "\(L("Request quota")): \(quota)"
        }
        if policy.usesSyntheticRollingRegen,
           let regen = Self.syntheticRollingRegenDetail(
               window: primary,
               now: input.now,
               showUsed: input.usageBarsShowUsed)
        {
            presentation.resetText = regen.resetText
            Self.apply(regen.pace, to: &presentation)
        }
        // Provider-specific by design: DeepSeek's balance description is provider-owned copy localized here.
        if input.provider == .deepseek, let detail = presentation.detailText {
            presentation.detailText = Self.localizedDeepSeekBalanceDescription(detail)
        }
        if policy.movesPrimaryDetailToStatus(snapshot: input.snapshot) {
            presentation.statusText = presentation.detailText
            presentation.detailText = nil
        }
    }

    private static func apply(_ paceDetail: PaceDetail, to presentation: inout PrimaryMetricPresentation) {
        presentation.detailLeft = paceDetail.leftLabel
        presentation.detailRight = paceDetail.rightLabel
        presentation.pacePercent = paceDetail.pacePercent
        presentation.paceOnTop = paceDetail.paceOnTop
        presentation.detailIsPaceDerived = paceDetail.isPaceDerived
    }

    private static func nonEmptyResetDescription(_ window: RateWindow) -> String? {
        guard let detail = window.resetDescription,
              !detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return detail
    }

    private static func trimmedResetDescription(_ window: RateWindow) -> String? {
        guard let detail = window.resetDescription?.trimmingCharacters(in: .whitespacesAndNewlines),
              !detail.isEmpty
        else { return nil }
        return detail
    }

    static func redactedMetricDetail(_ detail: String?, provider _: UsageProvider, metricID _: String) -> String? {
        guard let detail else { return nil }
        return PersonalInfoRedactor.redactEmails(in: detail, isEnabled: true)
    }

    static func blockingQuotaMetrics(_ metrics: [Metric], input: Input, snapshot: UsageSnapshot) -> [Metric] {
        guard let policy = ProviderDescriptorRegistry.descriptor(for: input.provider).presentation.menuCard
            .blockingQuota,
            let blocker = snapshot.extraRateWindows?.first(where: { $0.id == policy.windowID && $0.usageKnown })
        else { return metrics }
        return metrics.map { metric in
            let window: RateWindow? = switch metric.id {
            case "primary": snapshot.primary
            case "secondary": snapshot.secondary
            case "tertiary": snapshot.tertiary
            default: snapshot.extraRateWindows?.first { $0.id == metric.id && $0.usageKnown }?.window
            }
            guard let window, !window.isSyntheticPlaceholder,
                  let projection = RateWindow.bindingQuotaProjection(
                      primary: window, bindingLanes: [blocker.window], now: input.now)
            else { return metric }
            var blocked = metric
            blocked.percent = input.usageBarsShowUsed ? projection.usedPercent : 100 - projection.usedPercent
            blocked.statusText = L(policy.message)
            // The blocking quota's own row owns its reset; shorter resets cannot restore access.
            blocked.resetText = nil
            blocked.detailText = nil
            blocked.detailLeftText = nil
            blocked.detailRightText = nil
            blocked.pacePercent = nil
            blocked.sessionEquivalentDetail = nil
            return blocked
        }
    }

    /// Clear only pace fields, preserving unrelated quota and workday decorations.
    static func paceGatedMetrics(_ metrics: [Metric], paceVisible: Bool) -> [Metric] {
        guard !paceVisible else { return metrics }
        return metrics.map { metric in
            var result = metric
            // Provider-owned balance and reset text shares these slots with pace forecasts.
            if metric.detailIsPaceDerived {
                result.detailLeftText = nil
                result.detailRightText = nil
            }
            result.pacePercent = nil
            result.sessionEquivalentDetail = nil
            return result
        }
    }

    static func redactedMetrics(
        _ metrics: [Metric],
        provider: UsageProvider,
        hidePersonalInfo: Bool) -> [Metric]
    {
        guard hidePersonalInfo else { return metrics }
        return metrics.map { metric in
            var result = metric
            result.title = PersonalInfoRedactor.redactEmails(in: metric.title, isEnabled: true) ?? metric.title
            result.statusText = PersonalInfoRedactor.redactEmails(in: metric.statusText, isEnabled: true)
            result.resetText = PersonalInfoRedactor.redactEmails(in: metric.resetText, isEnabled: true)
            result.detailText = Self.redactedMetricDetail(metric.detailText, provider: provider, metricID: metric.id)
            result.detailLeftText = PersonalInfoRedactor.redactEmails(in: metric.detailLeftText, isEnabled: true)
            result.detailRightText = PersonalInfoRedactor.redactEmails(in: metric.detailRightText, isEnabled: true)
            return result
        }
    }

    static func usageNotes(input: Input) -> [String] {
        let subscriptionNotes = self.subscriptionMetadataNotes(snapshot: input.snapshot, provider: input.provider)

        if input.provider == .claude, input.snapshot?.dataConfidence == .percentOnly {
            // Both CLI scraping and restored history carry percentages without full usage detail.
            return [L("claude_limited_usage_detail")] + subscriptionNotes
        }

        // Provider-specific by design: OpenCode Go local quota windows need an explicit authority warning.
        if input.provider == .opencodego, input.snapshot?.dataConfidence == .estimated {
            return [L("Quota estimated from local usage history")] + subscriptionNotes
        }

        if let notes = self.apiProviderUsageNotes(input: input) {
            return notes + subscriptionNotes
        }

        return subscriptionNotes
    }

    var isOverviewErrorOnly: Bool {
        self.subtitleStyle == .error &&
            self.metrics.isEmpty &&
            self.usageNotes.isEmpty &&
            self.providerDetails.isEmpty &&
            self.inlineUsageDashboard == nil &&
            self.throughput == nil &&
            self.limitResetCredits == nil &&
            self.cloudCredits == nil &&
            self.creditsRemaining == nil &&
            self.providerCost == nil &&
            self.tokenUsage == nil &&
            self.placeholder == nil
    }

    var hasUsageContent: Bool {
        !self.metrics.isEmpty ||
            !self.usageNotes.isEmpty ||
            !self.providerDetails.isEmpty ||
            self.inlineUsageDashboard != nil ||
            self.throughput != nil ||
            self.limitResetCredits != nil ||
            self.cloudCredits != nil ||
            self.placeholder != nil
    }

    /// The cloud-credit row only needs a divider when another usage row is drawn before it.
    var hasUsageContentAboveCloudCredits: Bool {
        !self.metrics.isEmpty ||
            !self.usageNotes.isEmpty ||
            !self.providerDetails.isEmpty ||
            self.inlineUsageDashboard != nil ||
            self.throughput != nil ||
            self.limitResetCredits != nil
    }

    func showsOverviewSupplementalContent(compact: Bool) -> Bool {
        !compact || self.metrics.isEmpty
    }

    var creditsOnlyInlineUsageDashboard: Bool {
        self.creditsText != nil &&
            self.throughput == nil &&
            self.inlineUsageDashboard != nil &&
            self.metrics.isEmpty &&
            self.usageNotes.isEmpty &&
            self.providerDetails.isEmpty &&
            self.limitResetCredits == nil &&
            self.cloudCredits == nil &&
            self.placeholder == nil
    }

    var usesStackedDetailLayout: Bool {
        !self.metrics.isEmpty ||
            self.creditsText != nil ||
            self.limitResetCredits != nil ||
            self.cloudCredits != nil ||
            self.providerCost != nil ||
            self.tokenUsage != nil
    }

    func hasCompatibleTrackedLayout(with candidate: Self) -> Bool {
        self.hasCompatibleTrackedLayout(with: candidate, includeMetrics: true)
    }

    func hasCompatibleTrackedLayoutIgnoringMetrics(with candidate: Self) -> Bool {
        self.hasCompatibleTrackedLayout(with: candidate, includeMetrics: false)
    }

    func hasCompatibleTrackedMetricSubset(of candidate: Self) -> Bool {
        guard self.metrics.count < candidate.metrics.count,
              self.hasCompatibleTrackedLayoutIgnoringMetrics(with: candidate)
        else {
            return false
        }
        return self.metrics.allSatisfy { metric in
            candidate.metrics.contains { Self.hasCompatibleMetricLayout(metric, $0) }
        }
    }

    private func hasCompatibleTrackedLayout(with candidate: Self, includeMetrics: Bool) -> Bool {
        guard self.provider == candidate.provider,
              self.accountIdentityFingerprint == candidate.accountIdentityFingerprint,
              !includeMetrics || self.metrics.count == candidate.metrics.count,
              self.usageNotes == candidate.usageNotes,
              self.throughput?.summaryLine == candidate.throughput?.summaryLine,
              self.throughput?.presentation?.action == candidate.throughput?.presentation?.action,
              self.throughput?.presentation?.limitLine == candidate.throughput?.presentation?.limitLine,
              self.providerDetails == candidate.providerDetails,
              self.creditsShowProgress == candidate.creditsShowProgress,
              Self.hasCompatibleCreditsLayout(
                  currentText: self.creditsText,
                  currentRemaining: self.creditsRemaining,
                  candidateText: candidate.creditsText,
                  candidateRemaining: candidate.creditsRemaining),
              self.creditsHintText == candidate.creditsHintText,
              Self.hasCompatibleLimitResetCreditsLayout(self.limitResetCredits, candidate.limitResetCredits),
              Self.hasCompatibleProviderCostLayout(self.cloudCredits, candidate.cloudCredits),
              self.placeholder == candidate.placeholder,
              Self.hasCompatibleDashboardLayout(self.inlineUsageDashboard, candidate.inlineUsageDashboard),
              Self.hasCompatibleProviderCostLayout(self.providerCost, candidate.providerCost),
              Self.hasCompatibleTokenUsageLayout(self.tokenUsage, candidate.tokenUsage)
        else {
            return false
        }

        guard includeMetrics else { return true }
        return zip(self.metrics, candidate.metrics).allSatisfy(Self.hasCompatibleMetricLayout)
    }

    private static func hasCompatibleLimitResetCreditsLayout(
        _ current: LimitResetCreditsPresentation?,
        _ candidate: LimitResetCreditsPresentation?) -> Bool
    {
        // The hosted section has a fixed shape; its count and expiry strings can update in place.
        (current == nil) == (candidate == nil)
    }

    private static func hasCompatibleMetricLayout(_ current: Metric, _ candidate: Metric) -> Bool {
        let currentMetaText = current.linePresentation(title: current.title).metaText
        let candidateMetaText = candidate.linePresentation(title: candidate.title).metaText
        return current.id == candidate.id &&
            current.title == candidate.title &&
            current.percentStyle == candidate.percentStyle &&
            (current.statusText == nil) == (candidate.statusText == nil) &&
            (current.resetText == nil) == (candidate.resetText == nil) &&
            (current.detailText == nil) == (candidate.detailText == nil) &&
            (candidateMetaText == nil || currentMetaText != nil) &&
            current.cardStyle == candidate.cardStyle
    }

    private static func hasCompatibleCreditsLayout(
        currentText: String?,
        currentRemaining: Double?,
        candidateText: String?,
        candidateRemaining: Double?) -> Bool
    {
        switch (currentText, candidateText) {
        case (nil, nil):
            return true
        case let (currentText?, candidateText?):
            guard (currentRemaining == nil) == (candidateRemaining == nil) else { return false }
            // Numeric balances render as a fixed single line beside the full-scale label.
            // Multiline workspace balances retain their measured text until the menu reopens.
            return currentRemaining != nil || currentText == candidateText
        default:
            return false
        }
    }

    private static func hasCompatibleDashboardLayout(
        _ current: InlineUsageDashboardModel?,
        _ candidate: InlineUsageDashboardModel?) -> Bool
    {
        switch (current, candidate) {
        case (nil, nil):
            true
        case let (current?, candidate?):
            current.valueStyle == candidate.valueStyle &&
                current.kpis.count == candidate.kpis.count &&
                current.points.count == candidate.points.count &&
                current.quotaWindows.count == candidate.quotaWindows.count &&
                current.detailLines.count == candidate.detailLines.count &&
                zip(current.kpis, candidate.kpis).allSatisfy {
                    $0.title == $1.title && $0.emphasis == $1.emphasis
                } &&
                zip(current.points, candidate.points).allSatisfy {
                    $0.id == $1.id && $0.label == $1.label
                } &&
                zip(current.quotaWindows, candidate.quotaWindows).allSatisfy {
                    $0.title == $1.title && $0.range == $1.range && $0.note == $1.note
                }
        default:
            false
        }
    }

    private static func hasCompatibleProviderCostLayout(
        _ current: ProviderCostSection?,
        _ candidate: ProviderCostSection?) -> Bool
    {
        switch (current, candidate) {
        case (nil, nil):
            true
        case let (current?, candidate?):
            current.title == candidate.title &&
                (current.percentUsed == nil) == (candidate.percentUsed == nil) &&
                (current.percentLine == nil) == (candidate.percentLine == nil) &&
                (current.personalSpendLine == nil) == (candidate.personalSpendLine == nil)
        default:
            false
        }
    }

    private static func hasCompatibleTokenUsageLayout(
        _ current: TokenUsageSection?,
        _ candidate: TokenUsageSection?) -> Bool
    {
        switch (current, candidate) {
        case (nil, nil):
            true
        case let (current?, candidate?):
            current.hintLine == candidate.hintLine &&
                current.errorLine == candidate.errorLine &&
                (current.meteredLine == nil) == (candidate.meteredLine == nil) &&
                current.comparisonLines.count == candidate.comparisonLines.count
        default:
            false
        }
    }

    static func progressColor(for provider: UsageProvider) -> Color {
        let branding = ProviderDescriptorRegistry.descriptor(for: provider).branding
        if branding.progressColorStyle == .label {
            return Color(nsColor: .labelColor)
        }

        let color = ProviderAccentPalette.color(for: provider)
        return Color(red: color.red, green: color.green, blue: color.blue)
    }

    static func rateWindowLabels(
        input: Input,
        snapshot: UsageSnapshot) -> (primary: String, secondary: String, tertiary: String, showsTertiary: Bool)
    {
        let presentation = ProviderDescriptorRegistry.descriptor(for: input.provider).presentation
        let primaryLabel = presentation.rateWindowLabels(
            metadata: input.metadata, snapshot: snapshot, now: input.now).primary
        let secondaryLabel = presentation.rateWindowLabels(
            metadata: input.metadata, snapshot: snapshot, now: input.now).secondary
        let tertiaryLabel = input.metadata.opusLabel.map(L) ?? L("Sonnet")
        return (
            localizedSessionQuotaLabel(primaryLabel, windowMinutes: snapshot.primary?.windowMinutes),
            L(secondaryLabel),
            tertiaryLabel,
            input.metadata.supportsOpus)
    }

    static func sub2APILocalizedDetails(_ details: [ProviderDetailSection]) -> [ProviderDetailSection] {
        details.map { section in
            guard section.title == "Usage summary" else { return section }

            do {
                var rows: [ProviderDetailSection.Row] = []
                var consumedLabels: Set<String> = []

                if let balance = section.rows.first(where: { $0.label == "Balance" }) {
                    try rows.append(ProviderDetailSection.Row(
                        label: L("Balance"),
                        value: balance.value,
                        secondaryValue: balance.secondaryValue))
                    consumedLabels.insert(balance.label)
                }

                for period in [
                    (label: "Today", requests: "Today requests", tokens: "Today tokens"),
                    (label: "Total", requests: "All time requests", tokens: "All time tokens"),
                ] {
                    guard let requests = section.rows.first(where: { $0.label == period.requests }),
                          let tokens = section.rows.first(where: { $0.label == period.tokens })
                    else { continue }

                    var secondaryParts = ["\(tokens.value) \(L("tokens"))"]
                    if let cost = tokens.secondaryValue {
                        secondaryParts.append("\(L("Cost")): \(cost)")
                    }
                    try rows.append(ProviderDetailSection.Row(
                        label: L(period.label),
                        value: "\(requests.value) \(L("requests"))",
                        secondaryValue: secondaryParts.joined(separator: " · ")))
                    consumedLabels.formUnion([period.requests, period.tokens])
                }

                rows.append(contentsOf: section.rows.filter { !consumedLabels.contains($0.label) })
                return try ProviderDetailSection(title: L("Usage"), rows: rows, chart: section.chart)
            } catch {
                return section
            }
        }
    }

    static func resetText(
        for window: RateWindow,
        style: ResetTimeDisplayStyle,
        now: Date) -> String?
    {
        UsageFormatter.resetLine(for: window, style: style, now: now)
    }

    static func placeholder(input: Input) -> String? {
        if self.shouldShowRateLimitsUnavailablePlaceholder(input: input) {
            return L("Limits not available")
        }

        if input.snapshot == nil, !input.isRefreshing, input.lastError == nil {
            return L("No usage yet")
        }

        return nil
    }

    static func lastError(input: Input) -> String? {
        guard let lastError = input.lastError?.trimmingCharacters(in: .whitespacesAndNewlines),
              !lastError.isEmpty
        else {
            return nil
        }
        if self.shouldShowRateLimitsUnavailablePlaceholder(input: input, lastError: lastError) {
            return nil
        }
        return lastError
    }

    static func dashboardHint(error: String?) -> String? {
        guard let error, !error.isEmpty else { return nil }
        return error
    }

    static func subscriptionMetadataNotes(snapshot: UsageSnapshot?, provider: UsageProvider) -> [String] {
        guard let snapshot else { return [] }
        if let renewsAt = snapshot.subscriptionRenewsAt {
            return [String(
                format: L("Plan renews: %@"),
                self.subscriptionDateString(
                    renewsAt,
                    provider: provider,
                    dateOnly: snapshot.subscriptionRenewsAtIsDateOnly))]
        }
        if let expiresAt = snapshot.subscriptionExpiresAt {
            return [String(
                format: L("Plan expires: %@"),
                self.subscriptionDateString(
                    expiresAt,
                    provider: provider,
                    dateOnly: snapshot.subscriptionExpiresAtIsDateOnly))]
        }
        return []
    }

    private static func subscriptionDateString(
        _ date: Date,
        provider: UsageProvider,
        dateOnly: Bool = false) -> String
    {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.timeZone = dateOnly ? TimeZone(secondsFromGMT: 0) : self.subscriptionDateTimeZone(provider: provider)
        formatter.setLocalizedDateFormatFromTemplate("MMM d, yyyy")
        return formatter.string(from: date)
    }

    private static func subscriptionDateTimeZone(provider: UsageProvider) -> TimeZone {
        .current
    }

    private static func shouldShowRateLimitsUnavailablePlaceholder(input: Input, lastError: String? = nil) -> Bool {
        let currentError = lastError ?? input.lastError
        if let currentError = currentError?.trimmingCharacters(in: .whitespacesAndNewlines),
           !currentError.isEmpty,
           !ClaudeStatusProbe.isSubscriptionQuotaUnavailableDescription(currentError)
        {
            return false
        }
        if input.limitsAvailability?.isUnavailable == true {
            return true
        }
        return self.rateLimitsUnavailable(input: input, lastError: currentError)
    }

    private static func rateLimitsUnavailable(input: Input, lastError: String? = nil) -> Bool {
        UsageLimitsAvailability.resolve(
            provider: input.provider,
            snapshot: input.snapshot,
            lastErrorDescription: lastError ?? input.lastError)
            .isUnavailable
    }

    static func sessionPaceDetail(
        provider: UsageProvider,
        window: RateWindow,
        now: Date,
        showUsed: Bool) -> PaceDetail?
    {
        guard let detail = UsagePaceText.sessionDetail(provider: provider, window: window, now: now) else { return nil }
        return self.paceDetail(detail, window: window, showUsed: showUsed)
    }

    static func weeklyPaceDetail(
        provider: UsageProvider,
        window: RateWindow,
        now: Date,
        pace: UsagePace?,
        showUsed: Bool) -> PaceDetail?
    {
        guard let pace, window.remainingPercent > 0 else { return nil }
        let detail = UsagePaceText.weeklyDetail(provider: provider, pace: pace, now: now)
        return self.paceDetail(detail, window: window, showUsed: showUsed)
    }

    private static func paceDetail(
        _ detail: UsagePaceText.WeeklyDetail,
        window: RateWindow,
        showUsed: Bool) -> PaceDetail?
    {
        guard detail.expectedUsedPercent.isFinite, window.usedPercent.isFinite else { return nil }
        let expectedPercent = showUsed ? detail.expectedUsedPercent : (100 - detail.expectedUsedPercent)
        return PaceDetail(
            leftLabel: detail.leftLabel,
            rightLabel: detail.rightLabel,
            pacePercent: detail.stage == .onTrack ? nil : expectedPercent,
            paceOnTop: window.usedPercent <= detail.expectedUsedPercent,
            isPaceDerived: true)
    }

    static func standardWeeklyPace(input: Input, window: RateWindow) -> UsagePace? {
        if let weeklyPace = input.weeklyPace {
            return weeklyPace
        }
        return Self.displayableWeeklyPace(UsagePace.weekly(
            window: window,
            now: input.now,
            defaultWindowMinutes: 10080,
            workDays: input.workDaysPerWeek))
    }

    private static func displayableWeeklyPace(_ pace: UsagePace?) -> UsagePace? {
        guard let pace else { return nil }
        return pace.expectedUsedPercent >= 3 || pace.etaSeconds == 0 ? pace : nil
    }

    static func resetWindowPaceDetail(
        window: RateWindow,
        input: Input,
        pace: UsagePace? = nil) -> PaceDetail?
    {
        let capability = ProviderDescriptorRegistry.descriptor(for: input.provider).pace
        guard capability.supportsResetWindowPace(window: window, now: input.now),
              window.remainingPercent > 0
        else { return nil }
        let paceWindow = Self.resetWindowForPace(provider: input.provider, window: window)
        // A caller-supplied pace was measured against the raw window, so reuse it only when resolution
        // left the duration alone. Trusting it for a monthly sentinel would score the billing period as
        // a flat 30 days and silently undo the calendar-cycle resolution one line above.
        let reusablePace = paceWindow.windowMinutes == window.windowMinutes ? pace : nil
        let resolved = reusablePace ?? UsagePace.weekly(
            window: paceWindow,
            now: input.now,
            defaultWindowMinutes: 10080,
            workDays: input.workDaysPerWeek)
        guard let resolved = Self.displayableWeeklyPace(resolved) else { return nil }
        return Self.weeklyPaceDetail(
            provider: input.provider,
            window: paceWindow,
            now: input.now,
            pace: resolved,
            showUsed: input.usageBarsShowUsed)
    }

    private static func resetWindowForPace(provider: UsageProvider, window: RateWindow) -> RateWindow {
        // Provider snapshots use 30 days as a monthly sentinel; use the reset date for the real calendar-cycle length.
        ProviderDescriptorRegistry.descriptor(for: provider).pace.resolvedResetWindowForPace(window)
    }

    static func extraRateWindowMetrics(
        snapshot: UsageSnapshot,
        input: Input,
        percentStyle: PercentStyle) -> [Metric]
    {
        var extraRateWindows = snapshot.extraRateWindows ?? []
        if input.provider == .claude, input.showOptionalCreditsAndExtraUsage,
           MenuBarMetricWindowResolver.claudeSpendLimitWindow(snapshot: snapshot) != nil,
           let spend = snapshot.claudeMonthlySpendWindow
        {
            extraRateWindows.append(spend)
        }
        let menuCard = ProviderDescriptorRegistry.descriptor(for: input.provider).presentation.menuCard
        var visibleRateWindows = extraRateWindows
        if input.provider == .claude,
           !input.showOptionalCreditsAndExtraUsage || !input.claudeDailyRoutinesUsageVisible
        {
            visibleRateWindows.removeAll(where: Self.isClaudeDailyRoutinesRateWindow)
        }
        return visibleRateWindows.map { namedWindow in
            let paceDetail = Self.extraRateWindowPaceDetail(
                provider: input.provider,
                window: namedWindow.window,
                input: input)
            let usageKnown = namedWindow.usageKnown
            let resolvedResetText = Self.extraRateWindowResetText(
                namedWindow: namedWindow,
                input: input)
            let usesResetDetail = menuCard.extraRateWindowShowsResetDescriptionAsDetail(namedWindow)
            let resetText = usesResetDetail && namedWindow.window.resetsAt == nil
                ? nil
                : resolvedResetText
            let detailText: String? = if namedWindow.id == "claude-extra-usage" {
                Self.providerCostSection(
                    cost: snapshot.providerCost,
                    style: .claude,
                    preferredCurrencyCode: input.preferredCurrencyCode).map {
                    [$0.spendLine, $0.balanceLine].compactMap(\.self).joined(separator: " · ")
                }
            } else if usesResetDetail {
                namedWindow.window.resetDescription
            } else {
                nil
            }
            let statusText: String? = if usageKnown {
                nil
            } else if let resetText {
                "\(L("Unavailable")) - \(resetText)"
            } else {
                L("Unavailable")
            }
            // Provider-specific by design: Claude's canonical scoped title remains stable outside the menu.
            let title = if input.provider == .claude, namedWindow.id.hasPrefix("claude-weekly-scoped-") {
                String(format: L("%@ weekly"), namedWindow.title.replacingOccurrences(
                    of: #"\s+only\s*$"#, with: "", options: [.regularExpression, .caseInsensitive]))
            } else {
                L(namedWindow.title)
            }
            let detailLeftText = usageKnown ? paceDetail?.leftLabel : nil
            var metric = Metric(
                id: namedWindow.id,
                title: title,
                percent: Self.clamped(
                    input.usageBarsShowUsed
                        ? namedWindow.window.usedPercent
                        : namedWindow.window.remainingPercent),
                percentStyle: percentStyle,
                statusText: statusText,
                resetText: usageKnown ? resetText : nil,
                detailText: usageKnown ? detailText : nil,
                detailLeftText: detailLeftText,
                detailRightText: usageKnown ? paceDetail?.rightLabel : nil,
                pacePercent: usageKnown ? paceDetail?.pacePercent : nil,
                detailIsPaceDerived: paceDetail?.isPaceDerived ?? false,
                paceOnTop: paceDetail?.paceOnTop ?? true,
                sessionEquivalentDetail: usageKnown
                    ? Self.sessionEquivalentDetail(
                        input: input,
                        weeklyWindow: namedWindow.window,
                        weeklyWindowID: namedWindow.id)
                    : nil)
            if namedWindow.id == "claude-extra-usage", snapshot.providerCost?.resetsAt == nil {
                metric.helpText = L("cost_reset_inferred_tooltip", "Claude")
            }
            return metric
        }
    }

    private static func isClaudeDailyRoutinesRateWindow(_ namedWindow: NamedRateWindow) -> Bool {
        namedWindow.id == "claude-routines"
    }

    private static func extraRateWindowResetText(
        namedWindow: NamedRateWindow,
        input: Input) -> String?
    {
        self.resetText(
            for: namedWindow.window,
            style: input.resetTimeDisplayStyle,
            now: input.now)
    }

    private static func extraRateWindowPaceDetail(
        provider: UsageProvider,
        window: RateWindow,
        input: Input) -> PaceDetail?
    {
        if let detail = resetWindowPaceDetail(window: window, input: input) { return detail }
        // Provider-specific by design: extra-window pacing covers Claude 7-day extras.
        guard provider == .claude, window.windowMinutes == 10080 else {
            return nil
        }
        switch window.windowMinutes {
        case 300:
            return self.sessionPaceDetail(
                provider: provider,
                window: window,
                now: input.now,
                showUsed: input.usageBarsShowUsed)
        case 10080:
            let pace = Self.displayableWeeklyPace(UsagePace.weekly(
                window: window,
                now: input.now,
                defaultWindowMinutes: 10080,
                workDays: input.workDaysPerWeek))
            return Self.weeklyPaceDetail(
                provider: provider,
                window: window,
                now: input.now,
                pace: pace,
                showUsed: input.usageBarsShowUsed)
        default:
            return nil
        }
    }

    static func syntheticRegenDetail(
        weekly: RateWindow,
        cost: ProviderCostSnapshot?,
        now: Date,
        showUsed: Bool) -> (resetText: String, pace: PaceDetail)?
    {
        guard let cost,
              cost.limit > 0,
              let nextRegenAmount = cost.nextRegenAmount,
              nextRegenAmount > 0,
              let resetsAt = weekly.resetsAt
        else { return nil }

        let countdown = UsageFormatter.resetCountdownDescription(from: resetsAt, now: now)
        let resetText = String(format: L("Regenerates %@"), countdown)

        let nextRegenPercent = (nextRegenAmount / cost.limit) * 100
        let afterNextRegenRemaining = min(100, weekly.remainingPercent + nextRegenPercent)
        let afterNextRegen = showUsed ? max(0, 100 - afterNextRegenRemaining) : afterNextRegenRemaining
        let suffix = showUsed ? L("used after next regen") : L("after next regen")
        let ticksToFull = max(0, cost.used) / nextRegenAmount
        let left = String(format: "%.0f%% %@", afterNextRegen, suffix)
        let right = if ticksToFull <= 0.1 {
            L("Near full")
        } else if ticksToFull < 1.5 {
            L("Full in ~1 regen")
        } else {
            String(format: L("Full in ~%.0f regens"), ceil(ticksToFull))
        }
        return (resetText, PaceDetail(
            leftLabel: left,
            rightLabel: right,
            pacePercent: nil,
            paceOnTop: true,
            isPaceDerived: true))
    }

    static func syntheticRollingRegenDetail(
        window: RateWindow,
        now: Date,
        showUsed: Bool) -> (resetText: String, pace: PaceDetail)?
    {
        guard let resetsAt = window.resetsAt,
              let nextRegenPercent = window.nextRegenPercent,
              nextRegenPercent > 0
        else { return nil }

        let countdown = UsageFormatter.resetCountdownDescription(from: resetsAt, now: now)
        let resetText = String(format: L("Regenerates %@"), countdown)

        let afterNextRegenRemaining = min(100, window.remainingPercent + nextRegenPercent)
        let afterNextRegen = showUsed ? max(0, 100 - afterNextRegenRemaining) : afterNextRegenRemaining
        let suffix = showUsed ? L("used after next regen") : L("after next regen")
        let left = String(format: "%.0f%% %@", afterNextRegen, suffix)

        let missingPercent = max(0, window.usedPercent)
        let ticksToFull = missingPercent / nextRegenPercent
        let right = if ticksToFull <= 0.1 {
            L("Near full")
        } else if ticksToFull < 1.5 {
            L("Full in ~1 regen")
        } else {
            String(format: L("Full in ~%.0f regens"), ceil(ticksToFull))
        }

        return (resetText, PaceDetail(
            leftLabel: left,
            rightLabel: right,
            pacePercent: nil,
            paceOnTop: true,
            isPaceDerived: true))
    }
}
