import BarsCore
import Commander
import Foundation

extension BarsCLI {
    private static let costSupportedProviders = Set(
        ProviderDescriptorRegistry.all.filter(\.cli.supportsCostCommand).map(\.id))

    static func runCost(_ values: ParsedValues) async {
        let output = CLIOutputPreferences.from(values: values)
        let config = BarsCLI.loadConfig(output: output)
        let selection = BarsCLI.decodeProvider(from: values, config: config)
        let providers = Self.costProviders(from: selection)
        let unsupported = selection.asList.filter { !Self.costSupportedProviders.contains($0) }
        if !unsupported.isEmpty {
            let names = unsupported
                .map { ProviderDescriptorRegistry.descriptor(for: $0).metadata.displayName }
                .sorted()
                .joined(separator: ", ")
            if !output.jsonOnly {
                Self.writeStderr("Skipping providers without local cost usage: \(names)\n")
            }
        }
        guard !providers.isEmpty else {
            Self.exit(
                code: .failure,
                message: "Error: cost is only supported for \(Self.costSupportedProviderNames()).",
                output: output,
                kind: .args)
        }

        let format = output.format
        let forceRefresh = values.flags.contains("refresh")
        let includeBreakdown = values.flags.contains("breakdown")
        let useColor = Self.shouldUseColor(noColor: values.flags.contains("noColor"), format: format)
        let now = Date()
        let bucketCalendar = CostUsageBucketTimeZone.calendar(
            identifier: Self.stringFromAppDefaults("tokenCostUsageBucketTimeZone"))
        let period = Self.decodeCostReportingPeriod(from: values, saved: Self.costReportingPeriodFromDefaults())
        let historyDays = period.days(now: now, calendar: bucketCalendar)
        let fetcher = CostUsageFetcher(calendar: bucketCalendar)
        var sections: [String] = []
        var payload: [CostPayload] = []
        var exitCode: ExitCode = .success

        for provider in providers {
            do {
                let snapshot = try await fetcher.loadTokenSnapshot(
                    provider: provider,
                    environment: ProviderConfigEnvironment.applyAPIKeyOverride(
                        base: ProcessInfo.processInfo.environment,
                        provider: provider,
                        config: config.providerConfig(for: provider.instanceID)),
                    now: now,
                    forceRefresh: forceRefresh,
                    historyDays: historyDays,
                    refreshPricingInBackground: false).reporting(period)
                switch format {
                case .text:
                    sections.append(Self.renderCostText(
                        provider: provider,
                        snapshot: snapshot,
                        useColor: useColor,
                        calendar: bucketCalendar,
                        includeBreakdown: includeBreakdown))
                case .json:
                    payload.append(Self.makeCostPayload(
                        provider: provider,
                        snapshot: snapshot,
                        error: nil,
                        calendar: bucketCalendar))
                }
            } catch {
                exitCode = Self.mapError(error)
                if format == .json {
                    payload.append(Self.makeCostPayload(provider: provider, snapshot: nil, error: error))
                } else if !output.jsonOnly {
                    Self.writeStderr("Error: \(error.localizedDescription)\n")
                }
            }
        }

        switch format {
        case .text:
            if !sections.isEmpty {
                print(sections.joined(separator: "\n\n"))
            }
        case .json:
            if !payload.isEmpty {
                Self.printJSON(payload, pretty: output.pretty)
            }
        }

        Self.exit(code: exitCode, output: output, kind: exitCode == .success ? .runtime : .provider)
    }

    static func renderCostText(
        provider: UsageProvider,
        snapshot: CostUsageTokenSnapshot,
        useColor: Bool,
        calendar: Calendar = .current,
        includeBreakdown: Bool = false) -> String
    {
        let descriptor = ProviderDescriptorRegistry.descriptor(for: provider)
        let name = descriptor.metadata.displayName
        if descriptor.tokenCost.presentation == .tokensOnly {
            return Self.renderLocalTokenHistoryText(name: name, snapshot: snapshot, useColor: useColor)
        }
        // Vendor-metered spend is the vendor's own figure, so it is not an API-rate estimate.
        let isMetered = snapshot.costProvenance == .vendorMetered
        let header = Self.costHeaderLine(
            isMetered ? "\(name) Cost (billed)" : "\(name) Cost (API-rate estimate)",
            useColor: useColor)
        let historyNotice = snapshot.historyIsFullyScanned ? nil : "Partial local history · recorded token subtotal"

        let todayIncomplete = snapshot.summary(forLastDays: 1, calendar: calendar).incompleteRequestCount
        let incomplete = CostUsageIncompleteRequests.sum(snapshot.daily.map(\.incompleteRequestCount))
        let unpriced = snapshot.daily.reduce(0) { $0 + max(0, $1.unpricedRequestCount ?? 0) }
        let todayCost = snapshot.sessionCostUSD
            .map { UsageFormatter.currencyString($0, currencyCode: snapshot.currencyCode) } ?? "—"
        let todayTokens = snapshot.sessionTokens.map { UsageFormatter.tokenCountString($0) }
        let todayLine = todayTokens.map { "Today: \(todayCost) · \($0) tokens" } ?? "Today: \(todayCost)"

        let monthCost = snapshot.last30DaysCostUSD
            .map { UsageFormatter.currencyString($0, currencyCode: snapshot.currencyCode) } ?? "—"
        let monthTokens = snapshot.last30DaysTokens.map { UsageFormatter.tokenCountString($0) }
        let historyLabel = snapshot.periodLabel
        let monthLine = monthTokens.map {
            "\(historyLabel): \(monthCost) · \($0) tokens"
        } ?? "\(historyLabel): \(monthCost)"

        // Plan-metered spend over the same window (what Cursor actually deducts), shown alongside the
        // API-rate estimate. A vendor-metered total already *is* the billed figure, so it only earns a
        // second row when it disagrees with the window total.
        let meteredLine: String? = snapshot.meteredCostUSD.flatMap { metered in
            if isMetered, let total = snapshot.last30DaysCostUSD, abs(total - metered) < 0.005 {
                return nil
            }
            let amount = UsageFormatter.currencyString(metered, currencyCode: snapshot.currencyCode)
            return "Plan metered: \(amount) (\(historyLabel.lowercased()))"
        }

        var lines: [String?] = [
            header,
            todayLine + (todayIncomplete > 0 ? " · Incomplete" : ""),
            monthLine + (incomplete > 0 ? " · Incomplete" : ""),
            meteredLine,
        ]
        if incomplete > 0 {
            lines
                .append("Incomplete: \(incomplete) requests lacked final usage and were excluded from tokens and cost.")
        }
        if unpriced > 0 {
            lines.append("Partial estimate: \(unpriced) recorded request\(unpriced == 1 ? "" : "s") had no price.")
        }
        lines.append(historyNotice)
        // Provider-specific by design: Claude and OpenCode Go local history retain model attribution.
        if includeBreakdown, provider == .claude || provider == .opencodego, !snapshot.daily.isEmpty {
            lines.append(contentsOf: Self.tokenDetailLines(
                snapshot: snapshot,
                calendar: calendar,
                useColor: useColor))
        }
        lines.append(isMetered
            ? "Billed by \(name) from your workspace usage meters."
            : UsageFormatter.costEstimateHint(provider: provider))
        return lines.compactMap(\.self).joined(separator: "\n")
    }

    // MARK: - Local token detail (daily + model breakdown)

    private static func tokenDetailLines(
        snapshot: CostUsageTokenSnapshot,
        calendar: Calendar,
        useColor: Bool) -> [String]
    {
        // Single shared selection: daily and top-model sections describe the same window.
        let selection = Self.recentCostEntries(snapshot: snapshot, calendar: calendar)
        guard !selection.entries.isEmpty else { return [] }
        var out: [String] = []
        out.append(contentsOf: Self.dailyCostLines(
            entries: selection.entries,
            snapshot: snapshot,
            periodLabel: selection.periodLabel,
            useColor: useColor))
        out.append(contentsOf: Self.topCostModelLines(
            entries: selection.entries,
            snapshot: snapshot,
            periodLabel: selection.periodLabel,
            useColor: useColor))
        return out
    }

    private static func recentCostEntries(
        snapshot: CostUsageTokenSnapshot,
        calendar: Calendar) -> (entries: [CostUsageDailyReport.Entry], periodLabel: String)
    {
        guard !snapshot.daily.isEmpty else { return ([], "") }
        let today = calendar.startOfDay(for: snapshot.updatedAt)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        let intervalDays = min(7, max(1, snapshot.historyDays))
        let recentDayKeys = (0..<intervalDays).compactMap { offset -> String? in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            return formatter.string(from: day)
        }
        let recent = snapshot.daily.filter { recentDayKeys.contains($0.date) }
            .sorted { $0.date > $1.date }
        if !recent.isEmpty {
            let label = "last \(intervalDays) calendar day\(intervalDays == 1 ? "" : "s")"
            return (Array(recent.prefix(intervalDays)), label)
        }
        // Stale snapshot: fall back to the latest recorded days, capped at the
        // requested interval and labeled as recorded (never as calendar days).
        let recorded = snapshot.daily.sorted { $0.date > $1.date }.prefix(intervalDays)
        let label = "last \(recorded.count) recorded day\(recorded.count == 1 ? "" : "s")"
        return (Array(recorded), label)
    }

    private static func dailyCostLines(
        entries: [CostUsageDailyReport.Entry],
        snapshot: CostUsageTokenSnapshot,
        periodLabel: String,
        useColor: Bool) -> [String]
    {
        let title = "Daily breakdown (\(periodLabel)):"
        var out: [String] = ["", useColor ? "\u{001B}[1m\(title)\u{001B}[0m" : title]
        for entry in entries.reversed() {
            // A priced subtotal beside an unpriced model row is not the exact day cost.
            let hasUnpricedUsage = (entry.unpricedRequestCount ?? 0) > 0 || (entry.modelBreakdowns?.contains {
                $0.costUSD == nil && ($0.totalTokens ?? 0) > 0
            } ?? false)
            let cost = (hasUnpricedUsage ? nil : entry.costUSD)
                .map { UsageFormatter.currencyString($0, currencyCode: snapshot.currencyCode) }
                ?? "\u{2014}"
            let total = entry.totalTokens
                .map { UsageFormatter.tokenCountString($0) } ?? "\u{2014}"
            var parts: [String] = []
            if let v = entry.inputTokens { parts.append("in \(UsageFormatter.tokenCountString(v))") }
            if let v = entry.outputTokens { parts.append("out \(UsageFormatter.tokenCountString(v))") }
            if let v = entry.cacheReadTokens, v > 0 {
                parts.append("cacheRead \(UsageFormatter.tokenCountString(v))")
            }
            if let v = entry.cacheCreationTokens, v > 0 {
                parts.append("cacheCreate \(UsageFormatter.tokenCountString(v))")
            }
            let mix = parts.isEmpty ? "" : " (" + parts.joined(separator: ", ") + ")"
            let models = entry.modelsUsed?.isEmpty == false
                ? " \u{00B7} " + entry.modelsUsed!.prefix(2).joined(separator: ", ")
                + (entry.modelsUsed!.count > 2 ? " +\(entry.modelsUsed!.count - 2)" : "")
                : ""
            let incomplete = entry.incompleteRequestCount > 0 ? " · Incomplete" : ""
            out.append("\(entry.date): \(cost) \u{00B7} \(total) tokens\(mix)\(models)\(incomplete)")
        }
        return out
    }

    private static func topCostModelLines(
        entries: [CostUsageDailyReport.Entry],
        snapshot: CostUsageTokenSnapshot,
        periodLabel: String,
        useColor: Bool) -> [String]
    {
        var hasUnattributedDay = false
        struct ModelAggregate {
            var cost: Double? = 0
            var tokens: Int? = 0
            var days: Set<String> = []
            var incomplete = 0
            var hasUsage = false
        }
        var modelAgg: [String: ModelAggregate] = [:]
        for entry in entries {
            if (entry.unpricedRequestCount ?? 0) > 0 || entry.incompleteRequestCount > 0 {
                hasUnattributedDay = true
            }
            guard let breakdowns = entry.modelBreakdowns, !breakdowns.isEmpty else {
                let hasUsage = (entry.costUSD ?? 0) != 0 || (entry.totalTokens ?? 0) > 0
                if hasUsage { hasUnattributedDay = true }
                continue
            }
            for breakdown in breakdowns {
                var cur = modelAgg[breakdown.modelName] ?? ModelAggregate()
                cur.incomplete = CostUsageIncompleteRequests.sum([
                    cur.incomplete,
                    breakdown.incompleteRequestCount ?? 0,
                ])
                cur.days.insert(entry.date)
                let excludedOnly = (breakdown.incompleteRequestCount ?? 0) > 0
                    && breakdown.costUSD == nil && breakdown.totalTokens == nil
                if excludedOnly {
                    modelAgg[breakdown.modelName] = cur
                    continue
                }
                cur.hasUsage = true
                // Once unknown (nil), later additions must not resurrect a partial sum.
                if cur.cost != nil {
                    if let c = breakdown.costUSD {
                        cur.cost = cur.cost! + c
                    } else {
                        cur.cost = nil
                    }
                }
                if cur.tokens != nil {
                    if let t = breakdown.totalTokens {
                        let (result, overflow) = cur.tokens!.addingReportingOverflow(t)
                        cur.tokens = overflow ? nil : result
                    } else {
                        cur.tokens = nil
                    }
                }
                cur.days.insert(entry.date)
                modelAgg[breakdown.modelName] = cur
            }
        }
        guard !modelAgg.isEmpty else { return [] }
        let isPartial = !snapshot.historyIsFullyScanned || hasUnattributedDay
            || modelAgg.values.contains { !$0.hasUsage || $0.cost == nil || $0.tokens == nil }
        let sorted = modelAgg.sorted { lhs, rhs in
            let lCost = lhs.value.hasUsage ? lhs.value.cost ?? -1 : -1
            let rCost = rhs.value.hasUsage ? rhs.value.cost ?? -1 : -1
            if lCost != rCost { return lCost > rCost }
            let lTokens = lhs.value.hasUsage ? lhs.value.tokens ?? -1 : -1
            let rTokens = rhs.value.hasUsage ? rhs.value.tokens ?? -1 : -1
            if lTokens != rTokens { return lTokens > rTokens }
            return lhs.key < rhs.key
        }
        var out = [""]
        let title = isPartial
            ? "Top models (\(periodLabel) \u{2014} partial):"
            : "Top models (\(periodLabel)):"
        out.append(useColor ? "\u{001B}[1m\(title)\u{001B}[0m" : title)
        for (idx, item) in sorted.prefix(5).enumerated() {
            let costStr = (item.value.hasUsage ? item.value.cost : nil)
                .map { UsageFormatter.currencyString($0, currencyCode: snapshot.currencyCode) }
                ?? "\u{2014}"
            let tokensStr = (item.value.hasUsage ? item.value.tokens : nil)
                .map { UsageFormatter.tokenCountString($0) } ?? "\u{2014}"
            let days = item.value.days.count
            let display = UsageFormatter.modelDisplayName(item.key)
            let dayLabel = days == 1 ? "day" : "days"
            let incomplete = item.value.incomplete > 0 ? " · Incomplete" : ""
            let usage = "\(costStr) · \(tokensStr) tokens (\(days) \(dayLabel))\(incomplete)"
            out.append("\(idx + 1). \(display) — \(usage)")
        }
        if isPartial {
            out.append("Note: Ranking is partial (incomplete history or unattributed cost/tokens).")
        }
        return out
    }

    private static func renderLocalTokenHistoryText(
        name: String,
        snapshot: CostUsageTokenSnapshot,
        useColor: Bool) -> String
    {
        let header = Self.costHeaderLine("\(name) Token History", useColor: useColor)
        let hint = "Local token history · dollar costs unavailable"
        guard snapshot.historyCoverageIsEstablished || snapshot.last30DaysTokens != nil else {
            return [header, "Local token history is unavailable or incomplete.", hint].joined(separator: "\n")
        }
        let today = snapshot.sessionTokens.map { "\(UsageFormatter.tokenCountString($0)) tokens" } ?? "—"
        let total = snapshot.last30DaysTokens.map { "\(UsageFormatter.tokenCountString($0)) tokens" } ?? "—"
        let historyLabel = snapshot.periodLabel
        let lines: [String?] = [
            header,
            "Today: \(today)",
            snapshot.historyDays == 1 ? nil : "\(historyLabel): \(total)",
            snapshot.daily.isEmpty && snapshot.historyCoverageIsEstablished
                ? "No token usage found in the selected period." : nil,
            snapshot.historyIsFullyScanned ? nil : "Partial local history · recorded token subtotal",
            hint,
        ]
        return lines.compactMap(\.self).joined(separator: "\n")
    }

    private static func costHeaderLine(_ header: String, useColor: Bool) -> String {
        guard useColor else { return header }
        return "\u{001B}[1;36m\(header)\u{001B}[0m"
    }

    static func costProviders(from selection: ProviderSelection) -> [UsageProvider] {
        selection.asList.filter { Self.costSupportedProviders.contains($0) }
    }

    static func makeCostPayload(
        provider: UsageProvider,
        snapshot: CostUsageTokenSnapshot?,
        error: Error?,
        calendar: Calendar = .current) -> CostPayload
    {
        let daily = snapshot?.daily.map(Self.costDailyPayload(from:)) ?? []
        let summary = snapshot.map { $0.summary(forLastDays: $0.historyDays, calendar: calendar) }
        let last30Days = snapshot.map { Self.last30DaysTotals(from: $0, calendar: calendar) }

        return CostPayload(
            provider: provider.rawValue,
            source: "local",
            updatedAt: snapshot?.updatedAt ?? (error == nil ? nil : Date()),
            currencyCode: snapshot?.currencyCode,
            sessionTokens: snapshot?.sessionTokens,
            sessionCostUSD: snapshot?.sessionCostUSD,
            historyDays: snapshot?.historyDays,
            historyCoverageIsEstablished: snapshot?.historyCoverageIsEstablished,
            last30DaysTokens: last30Days?.tokens,
            last30DaysCostUSD: last30Days?.costUSD,
            meteredCostUSD: snapshot?.meteredCostUSD,
            daily: daily,
            totals: snapshot.flatMap { Self.costTotals($0, calendar: calendar) },
            provenance: summary?.provenance.rawValue,
            coverage: summary?.coverage,
            error: error.map { Self.makeErrorPayload($0) },
            incompleteRequestCount: snapshot
                .map { CostUsageIncompleteRequests.sum($0.daily.map(\.incompleteRequestCount)) },
            reportingPeriod: snapshot.map { ($0.reportingPeriod ?? .rolling(days: $0.historyDays)).rawValue },
            historyLabel: snapshot?.periodLabel)
    }

    private static func last30DaysTotals(
        from snapshot: CostUsageTokenSnapshot,
        calendar: Calendar) -> (tokens: Int?, costUSD: Double?)
    {
        // Snapshot aggregates describe the selected history. Keep the legacy short-history contract.
        guard snapshot.historyDays > 30 else {
            return (snapshot.last30DaysTokens, snapshot.last30DaysCostUSD)
        }
        let summary = snapshot.summary(forLastDays: 30, calendar: calendar)
        if summary.entryCount == 0, snapshot.historyIsFullyScanned {
            // Only known full-history amounts establish zero for an empty, fully scanned window.
            return (snapshot.last30DaysTokens == nil ? nil : 0, snapshot.last30DaysCostUSD == nil ? nil : 0)
        }
        return (summary.totalTokens, summary.totalCostUSD)
    }

    private static func costDailyPayload(from entry: CostUsageDailyReport.Entry) -> CostDailyEntryPayload {
        CostDailyEntryPayload(
            date: entry.date,
            inputTokens: entry.inputTokens,
            outputTokens: entry.outputTokens,
            cacheReadTokens: entry.cacheReadTokens,
            cacheCreationTokens: entry.cacheCreationTokens,
            reasoningTokens: entry.reasoningTokens,
            totalTokens: entry.totalTokens,
            costUSD: entry.costUSD,
            modelsUsed: entry.modelsUsed,
            modelBreakdowns: entry.modelBreakdowns?.map(self.costModelBreakdownPayload(from:)),
            incompleteRequestCount: entry.incompleteRequestCount)
    }

    private static func costModelBreakdownPayload(
        from breakdown: CostUsageDailyReport.ModelBreakdown) -> CostModelBreakdownPayload
    {
        CostModelBreakdownPayload(
            modelName: breakdown.modelName,
            costUSD: breakdown.costUSD,
            totalTokens: breakdown.totalTokens,
            incompleteRequestCount: breakdown.incompleteRequestCount)
    }

    private static func costTotals(_ snapshot: CostUsageTokenSnapshot, calendar: Calendar) -> CostTotalsPayload? {
        let entries = snapshot.daily
        guard !entries.isEmpty || snapshot.last30DaysTokens != nil || snapshot.last30DaysCostUSD != nil
        else { return nil }

        func sum(_ keyPath: KeyPath<CostUsageDailyReport.Entry, Int?>) -> Int? {
            let values = entries.compactMap { $0[keyPath: keyPath] }
            return values.isEmpty ? nil : CheckedSum.integers(values)
        }
        let costs = entries.compactMap(\.costUSD)
        let summary = entries.isEmpty ? nil : snapshot.summary(forLastDays: snapshot.historyDays, calendar: calendar)
        return CostTotalsPayload(
            totalInputTokens: sum(\.inputTokens),
            totalOutputTokens: sum(\.outputTokens),
            cacheReadTokens: sum(\.cacheReadTokens),
            cacheCreationTokens: sum(\.cacheCreationTokens),
            reasoningTokens: sum(\.reasoningTokens),
            totalTokens: sum(\.totalTokens) ?? snapshot.last30DaysTokens,
            totalCostUSD: costs.isEmpty ? snapshot.last30DaysCostUSD : costs.reduce(0, +),
            provenance: summary?.provenance.rawValue,
            coverage: summary?.coverage,
            incompleteRequestCount: CostUsageIncompleteRequests.sum(entries.map(\.incompleteRequestCount)))
    }

    static func decodeCostReportingPeriod(
        from values: ParsedValues,
        saved: CostReportingPeriod) -> CostReportingPeriod
    {
        if values.options["days"] == nil, let raw = values.options["period"]?.last,
           CostReportingPeriod(rawValue: raw) == nil
        {
            exit(
                code: .failure,
                message: "Error: --period must be month-to-date or all.",
                output: CLIOutputPreferences.from(values: values),
                kind: .args)
        }
        if let raw = values.options["days"]?.last, let days = Int(raw) {
            return .rolling(days: max(1, min(365, days)))
        }
        return values.options["period"]?.last.flatMap(CostReportingPeriod.init(rawValue:)) ?? saved
    }

    /// Human-readable list of providers that support a cost report, used by both `cost` and serve.
    static func costSupportedProviderNames() -> String {
        self.costSupportedProviders
            .map { ProviderDescriptorRegistry.descriptor(for: $0).metadata.displayName }
            .sorted()
            .joined(separator: ", ")
    }
}

struct CostOptions: CommanderParsable {
    @OptionGroup
    var common: CLICommonOptions

    @Option(
        name: .long("provider"),
        help: ProviderHelp.optionHelp)
    var provider: ProviderSelection?

    @Flag(name: .long("no-color"), help: "Disable ANSI colors in text output")
    var noColor: Bool = false

    @Flag(name: .long("refresh"), help: "Force refresh by ignoring cached scans")
    var refresh: Bool = false

    @Flag(name: .long("breakdown"), help: "Show daily and model breakdowns in Claude text output")
    var breakdown: Bool = false

    @Option(name: .long("period"), help: "Cost period: month-to-date or all; --days overrides this selection")
    var period: String?

    @Option(name: .long("days"), help: "Cost history window in days (1...365)")
    var days: Int?
}

struct CostPayload: Encodable, Sendable {
    let provider: String
    let source: String
    let updatedAt: Date?
    let currencyCode: String?
    let sessionTokens: Int?
    let sessionCostUSD: Double?
    let historyDays: Int?
    let reportingPeriod: String?
    let historyLabel: String?
    let historyCoverageIsEstablished: Bool?
    let last30DaysTokens: Int?
    let last30DaysCostUSD: Double?
    let meteredCostUSD: Double?
    let daily: [CostDailyEntryPayload]
    let totals: CostTotalsPayload?
    let provenance: String?
    let coverage: CostUsageCoverageCounts?
    let error: ProviderErrorPayload?

    let incompleteRequestCount: Int?

    init(
        provider: String,
        source: String,
        updatedAt: Date?,
        currencyCode: String? = nil,
        sessionTokens: Int?,
        sessionCostUSD: Double?,
        historyDays: Int?,
        historyCoverageIsEstablished: Bool? = nil,
        last30DaysTokens: Int?,
        last30DaysCostUSD: Double?,
        meteredCostUSD: Double? = nil,
        daily: [CostDailyEntryPayload],
        totals: CostTotalsPayload?,
        provenance: String? = nil,
        coverage: CostUsageCoverageCounts? = nil,
        error: ProviderErrorPayload?,
        incompleteRequestCount: Int? = nil,
        reportingPeriod: String? = nil,
        historyLabel: String? = nil)
    {
        self.incompleteRequestCount = incompleteRequestCount.flatMap { $0 > 0 ? $0 : nil }
        self.provider = provider
        self.source = source
        self.updatedAt = updatedAt
        self.currencyCode = currencyCode
        self.sessionTokens = sessionTokens
        self.sessionCostUSD = sessionCostUSD
        self.historyDays = historyDays
        self.reportingPeriod = reportingPeriod
        self.historyLabel = historyLabel
        self.historyCoverageIsEstablished = historyCoverageIsEstablished
        self.last30DaysTokens = last30DaysTokens
        self.last30DaysCostUSD = last30DaysCostUSD
        self.meteredCostUSD = meteredCostUSD
        self.daily = daily
        self.totals = totals
        self.provenance = provenance
        self.coverage = coverage
        self.error = error
    }
}

struct CostDailyEntryPayload: Encodable, Sendable {
    let date: String
    let inputTokens: Int?
    let outputTokens: Int?
    let cacheReadTokens: Int?
    let cacheCreationTokens: Int?
    let reasoningTokens: Int?
    let totalTokens: Int?
    let costUSD: Double?
    let modelsUsed: [String]?
    let modelBreakdowns: [CostModelBreakdownPayload]?

    private enum CodingKeys: String, CodingKey {
        case date
        case inputTokens
        case outputTokens
        case cacheReadTokens
        case cacheCreationTokens
        case reasoningTokens
        case totalTokens
        case costUSD = "totalCost"
        case modelsUsed
        case incompleteRequestCount
        case modelBreakdowns
    }

    let incompleteRequestCount: Int?

    init(
        date: String,
        inputTokens: Int?,
        outputTokens: Int?,
        cacheReadTokens: Int?,
        cacheCreationTokens: Int?,
        reasoningTokens: Int? = nil,
        totalTokens: Int?,
        costUSD: Double?,
        modelsUsed: [String]?,
        modelBreakdowns: [CostModelBreakdownPayload]?,
        incompleteRequestCount: Int? = nil)
    {
        self.incompleteRequestCount = incompleteRequestCount.flatMap { $0 > 0 ? $0 : nil }
        self.date = date
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.reasoningTokens = reasoningTokens
        self.totalTokens = totalTokens
        self.costUSD = costUSD
        self.modelsUsed = modelsUsed
        self.modelBreakdowns = modelBreakdowns
    }
}

struct CostModelBreakdownPayload: Encodable, Sendable {
    let modelName: String
    let costUSD: Double?
    let totalTokens: Int?

    let incompleteRequestCount: Int?

    private enum CodingKeys: String, CodingKey {
        case modelName
        case costUSD = "cost"
        case totalTokens
        case incompleteRequestCount
    }

    init(modelName: String, costUSD: Double?, totalTokens: Int?, incompleteRequestCount: Int? = nil) {
        self.modelName = modelName
        self.costUSD = costUSD
        self.totalTokens = totalTokens
        self.incompleteRequestCount = incompleteRequestCount.flatMap { $0 > 0 ? $0 : nil }
    }
}

struct CostTotalsPayload: Encodable, Sendable {
    let totalInputTokens: Int?
    let totalOutputTokens: Int?
    let cacheReadTokens: Int?
    let cacheCreationTokens: Int?
    let reasoningTokens: Int?
    let totalTokens: Int?
    let totalCostUSD: Double?
    let provenance: String?
    let coverage: CostUsageCoverageCounts?

    private enum CodingKeys: String, CodingKey {
        case totalInputTokens = "inputTokens"
        case totalOutputTokens = "outputTokens"
        case cacheReadTokens
        case cacheCreationTokens
        case reasoningTokens
        case totalTokens
        case totalCostUSD = "totalCost"
        case provenance
        case incompleteRequestCount
        case coverage
    }

    let incompleteRequestCount: Int?

    init(
        totalInputTokens: Int?,
        totalOutputTokens: Int?,
        cacheReadTokens: Int?,
        cacheCreationTokens: Int?,
        reasoningTokens: Int? = nil,
        totalTokens: Int?,
        totalCostUSD: Double?,
        provenance: String? = nil,
        coverage: CostUsageCoverageCounts? = nil,
        incompleteRequestCount: Int? = nil)
    {
        self.incompleteRequestCount = incompleteRequestCount.flatMap { $0 > 0 ? $0 : nil }
        self.totalInputTokens = totalInputTokens
        self.totalOutputTokens = totalOutputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.reasoningTokens = reasoningTokens
        self.totalTokens = totalTokens
        self.totalCostUSD = totalCostUSD
        self.provenance = provenance
        self.coverage = coverage
    }
}

// Intentionally empty.
