import Foundation

/// Spend and token counts OpenCode's Console reports for this workspace — the amounts it actually
/// metered and charged, not a list-price estimate.
///
/// The Console answers in micro-cents (one hundred-millionth of a US dollar), the same unit the Go
/// quota meters use, so percentages and dollars here share one source of truth. Quota windows stay
/// in `OpenCodeGoUsageSnapshot`; this type only feeds the cost and token history surfaces.
public struct OpenCodeGoBilledUsage: Sendable, Equatable {
    /// One model's billed totals across the requested window.
    public struct Model: Sendable, Equatable {
        public let model: String
        public let provider: String
        public let requests: Int?
        public let inputTokens: Int?
        public let outputTokens: Int?
        public let cacheReadTokens: Int?
        public let cacheCreationTokens: Int?
        public let totalTokens: Int?
        public let costUSD: Double?

        public init(
            model: String,
            provider: String,
            requests: Int? = nil,
            inputTokens: Int? = nil,
            outputTokens: Int? = nil,
            cacheReadTokens: Int? = nil,
            cacheCreationTokens: Int? = nil,
            totalTokens: Int? = nil,
            costUSD: Double? = nil)
        {
            self.model = model
            self.provider = provider
            self.requests = requests
            self.inputTokens = inputTokens
            self.outputTokens = outputTokens
            self.cacheReadTokens = cacheReadTokens
            self.cacheCreationTokens = cacheCreationTokens
            self.totalTokens = totalTokens
            self.costUSD = costUSD
        }
    }

    /// Window the totals and daily rows cover, in days.
    public let historyDays: Int
    public let requests: Int?
    public let inputTokens: Int?
    public let outputTokens: Int?
    public let cacheReadTokens: Int?
    public let cacheCreationTokens: Int?
    public let totalTokens: Int?
    public let costUSD: Double?
    public let models: [Model]
    public let daily: [CostUsageDailyReport.Entry]
    public let updatedAt: Date

    public init(
        historyDays: Int,
        requests: Int? = nil,
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        cacheReadTokens: Int? = nil,
        cacheCreationTokens: Int? = nil,
        totalTokens: Int? = nil,
        costUSD: Double? = nil,
        models: [Model] = [],
        daily: [CostUsageDailyReport.Entry] = [],
        updatedAt: Date)
    {
        self.historyDays = max(1, historyDays)
        self.requests = requests
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.totalTokens = totalTokens
        self.costUSD = costUSD
        self.models = models
        self.daily = daily
        self.updatedAt = updatedAt
    }

    /// The provider id OpenCode bills Go subscription requests under. Workspace exports also carry
    /// free Zen rows that were never billed to the Go meters.
    static let billableProvider = "opencode-go"
}

/// Parsing for the Console usage endpoints. Kept free of networking so fixtures can cover them.
enum OpenCodeGoConsoleUsageParser {
    /// Micro-cents per US dollar, matching the Console's quota meters and billing payloads.
    static let microCentsPerUSD = 100_000_000.0

    /// Console dollar fields are unsigned integers encoded as strings; a leading `-` marks a credit.
    static func usd(fromMicroCents value: Any?) -> Double? {
        guard let raw = self.stringValue(from: value) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = trimmed.hasPrefix("-") ? trimmed.dropFirst() : trimmed[...]
        guard !digits.isEmpty, digits.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) else { return nil }
        guard let microCents = Double(trimmed), microCents.isFinite else { return nil }
        return microCents / self.microCentsPerUSD
    }

    /// Console counts arrive as strings but tolerate plain numbers so fixtures stay simple.
    static func intValue(from value: Any?) -> Int? {
        guard let raw = self.stringValue(from: value) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = trimmed.hasPrefix("-") ? trimmed.dropFirst() : trimmed[...]
        guard !digits.isEmpty, digits.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) else { return nil }
        return Int(trimmed)
    }

    private static func stringValue(from value: Any?) -> String? {
        switch value {
        case is Bool:
            nil
        case let string as String:
            string
        case let number as NSNumber:
            number.stringValue
        default:
            nil
        }
    }

    // MARK: - Per-day export

    /// One billable row of `/console/api/v2/usage/export` after dropping account-identifying columns.
    struct ExportRow: Equatable {
        let day: String
        let provider: String
        let model: String
        let requests: Int?
        let inputTokens: Int?
        let outputTokens: Int?
        let cacheReadTokens: Int?
        let cacheCreationTokens: Int?
        let totalTokens: Int?
        let costUSD: Double?
    }

    /// Reads the Console usage CSV. Account columns (`user_type`, `user_id`, `user_name`) are parsed
    /// only to locate the fixed columns and are never retained.
    ///
    /// The Console sends CRLF line endings, which Swift models as a single `\r\n` grapheme, so splitting
    /// on `"\n"` alone never breaks the line — the whole file parses as one header row. Split on
    /// newline separators instead.
    static func parseExport(text: String) -> [ExportRow] {
        var rows: [ExportRow] = []
        var columns: [String: Int]?
        for line in text.split(whereSeparator: \.isNewline) where !line.isEmpty {
            let fields = self.splitCSV(String(line))
            guard !fields.isEmpty else { continue }
            let header = fields.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            if columns == nil {
                guard header.contains("day"), header.contains("provider"), header.contains("model") else {
                    continue
                }
                var map: [String: Int] = [:]
                for (index, name) in header.enumerated() where map[name] == nil {
                    map[name] = index
                }
                columns = map
                continue
            }
            guard let columns else { continue }
            func field(_ name: String) -> String? {
                guard let index = columns[name], index < fields.count else { return nil }
                return fields[index]
            }
            guard let day = field("day")?.trimmingCharacters(in: .whitespaces), !day.isEmpty,
                  let provider = field("provider")?.trimmingCharacters(in: .whitespaces), !provider.isEmpty,
                  let model = field("model")?.trimmingCharacters(in: .whitespaces), !model.isEmpty
            else {
                continue
            }
            let input = self.intValue(from: field("input_tokens"))
            let output = self.intValue(from: field("output_tokens"))
            let cacheRead = self.intValue(from: field("cache_read_tokens"))
            let cacheWrite = self.cacheCreation(
                write5m: self.intValue(from: field("cache_write_5m_tokens")),
                write1h: self.intValue(from: field("cache_write_1h_tokens")))
            rows.append(ExportRow(
                day: day,
                provider: provider,
                model: model,
                requests: self.intValue(from: field("requests")),
                inputTokens: input,
                outputTokens: output,
                cacheReadTokens: cacheRead,
                cacheCreationTokens: cacheWrite,
                totalTokens: self.sum([input, output, cacheRead, cacheWrite]),
                costUSD: self.usd(fromMicroCents: field("cost_micro_cents"))))
        }
        return rows
    }

    /// Splits one CSV line, honoring the double-quoted fields the export emits for account names.
    private static func splitCSV(_ line: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var quoted = false
        var iterator = line.makeIterator()
        var pending: Character?
        while let character = pending ?? iterator.next() {
            pending = nil
            if quoted {
                if character == "\"" {
                    if let next = iterator.next() {
                        if next == "\"" {
                            current.append("\"")
                        } else {
                            quoted = false
                            pending = next
                        }
                    } else {
                        quoted = false
                    }
                } else {
                    current.append(character)
                }
                continue
            }
            switch character {
            case "\"":
                quoted = true
            case ",":
                fields.append(current)
                current = ""
            case "\r":
                continue
            default:
                current.append(character)
            }
        }
        fields.append(current)
        return fields
    }

    // MARK: - Go activity

    /// One `/console/api/activity/go` day.
    struct ActivityDay: Equatable {
        let day: String
        let totalTokens: Int?
        let requests: Int?
        let costUSD: Double?
    }

    struct Activity: Equatable {
        let days: [ActivityDay]
    }

    static func parseActivity(text: String) -> Activity? {
        guard let data = text.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            return nil
        }
        let days: [ActivityDay] = (root["daily"] as? [[String: Any]] ?? []).compactMap { row in
            guard let day = row["date"] as? String, !day.isEmpty else { return nil }
            return ActivityDay(
                day: day,
                totalTokens: self.intValue(from: row["totalTokens"]),
                requests: self.intValue(from: row["totalRequests"]),
                costUSD: self.usd(fromMicroCents: row["totalCostMicroCents"]))
        }
        guard !days.isEmpty else { return nil }
        return Activity(days: days)
    }

    // MARK: - Assembly

    /// Groups billable export rows into one `Entry` per day, keeping per-model breakdowns so the
    /// Usage & Spend dashboard can attribute spend the way it does for local providers.
    static func dailyEntries(rows: [ExportRow]) -> [CostUsageDailyReport.Entry] {
        var order: [String] = []
        var grouped: [String: [ExportRow]] = [:]
        for row in rows where row.provider == OpenCodeGoBilledUsage.billableProvider {
            if grouped[row.day] == nil {
                order.append(row.day)
            }
            grouped[row.day, default: []].append(row)
        }
        return order.sorted().compactMap { day in
            guard let rows = grouped[day], !rows.isEmpty else { return nil }
            return self.entry(day: day, rows: rows)
        }
    }

    private static func entry(day: String, rows: [ExportRow]) -> CostUsageDailyReport.Entry {
        let mix = CostUsageTokenMix(
            inputTokens: Self.sum(rows.map(\.inputTokens)),
            outputTokens: Self.sum(rows.map(\.outputTokens)),
            cacheReadTokens: Self.sum(rows.map(\.cacheReadTokens)),
            cacheCreationTokens: Self.sum(rows.map(\.cacheCreationTokens)))
        let breakdowns = rows.map { row in
            CostUsageDailyReport.ModelBreakdown(
                modelName: row.model,
                costUSD: row.costUSD,
                totalTokens: row.totalTokens,
                requestCount: row.requests,
                inputTokens: row.inputTokens,
                outputTokens: row.outputTokens,
                cacheReadTokens: row.cacheReadTokens,
                cacheCreationTokens: row.cacheCreationTokens,
                reasoningTokens: nil)
        }
        let models = rows.map(\.model).reduce(into: [String]()) { unique, model in
            if !unique.contains(model) { unique.append(model) }
        }
        let costs = rows.map(\.costUSD)
        let requests = Self.sum(rows.map(\.requests))
        return CostUsageDailyReport.Entry(
            date: day,
            inputTokens: mix.inputTokens,
            outputTokens: mix.outputTokens,
            cacheReadTokens: mix.cacheReadTokens,
            cacheCreationTokens: mix.cacheCreationTokens,
            totalTokens: Self.sum(rows.map(\.totalTokens)),
            requestCount: requests,
            costUSD: costs.allSatisfy { $0 != nil } ? costs.compactMap(\.self).reduce(0, +) : nil,
            modelsUsed: models,
            modelBreakdowns: breakdowns,
            pricedRequestCount: costs.allSatisfy { $0 != nil } ? requests : nil)
    }

    /// Sums optional counts, staying `nil` when every input is missing so absent data never reads as 0.
    private static func sum(_ values: [Int?]) -> Int? {
        let present = values.compactMap(\.self)
        guard !present.isEmpty else { return nil }
        return CheckedSum.integers(present)
    }

    /// Cache writes are reported in two TTL buckets; both absent means the class was not measured.
    private static func cacheCreation(write5m: Int?, write1h: Int?) -> Int? {
        guard write5m != nil || write1h != nil else { return nil }
        return CheckedSum.integers([write5m ?? 0, write1h ?? 0])
    }

    /// Rolls one window of billable export rows into billed usage: per-day entries, per-model totals,
    /// and the window totals the Console's separate summary endpoint used to supply.
    static func billedUsage(
        rows: [ExportRow],
        historyDays: Int,
        updatedAt: Date) -> OpenCodeGoBilledUsage?
    {
        let billable = rows.filter { $0.provider == OpenCodeGoBilledUsage.billableProvider }
        guard !billable.isEmpty else { return nil }
        return OpenCodeGoBilledUsage(
            historyDays: historyDays,
            requests: self.sum(billable.map(\.requests)),
            inputTokens: self.sum(billable.map(\.inputTokens)),
            outputTokens: self.sum(billable.map(\.outputTokens)),
            cacheReadTokens: self.sum(billable.map(\.cacheReadTokens)),
            cacheCreationTokens: self.sum(billable.map(\.cacheCreationTokens)),
            totalTokens: self.sum(billable.map(\.totalTokens)),
            costUSD: self.totalCost(billable.map(\.costUSD)),
            models: self.models(from: billable),
            daily: self.dailyEntries(rows: billable),
            updatedAt: updatedAt)
    }

    /// Builds billed usage from the billing period's daily feed, which splits no token classes.
    static func billedUsage(
        activityDays: [ActivityDay],
        historyDays: Int,
        updatedAt: Date) -> OpenCodeGoBilledUsage?
    {
        let daily = activityDays.compactMap { day -> CostUsageDailyReport.Entry? in
            guard day.totalTokens != nil || day.costUSD != nil else { return nil }
            return CostUsageDailyReport.Entry(
                date: day.day,
                inputTokens: nil,
                outputTokens: nil,
                totalTokens: day.totalTokens,
                requestCount: day.requests,
                costUSD: day.costUSD,
                modelsUsed: nil,
                modelBreakdowns: nil,
                pricedRequestCount: day.costUSD != nil ? day.requests : nil)
        }
        guard !daily.isEmpty else { return nil }
        return OpenCodeGoBilledUsage(
            historyDays: historyDays,
            requests: self.sum(activityDays.map(\.requests)),
            totalTokens: self.sum(activityDays.map(\.totalTokens)),
            costUSD: self.totalCost(activityDays.map(\.costUSD)),
            daily: daily,
            updatedAt: updatedAt)
    }

    /// One total per model across the window, keeping only the models OpenCode bills Go for.
    private static func models(from rows: [ExportRow]) -> [OpenCodeGoBilledUsage.Model] {
        var order: [String] = []
        var grouped: [String: [ExportRow]] = [:]
        for row in rows {
            if grouped[row.model] == nil {
                order.append(row.model)
            }
            grouped[row.model, default: []].append(row)
        }
        return order.map { model in
            let rows = grouped[model] ?? []
            return OpenCodeGoBilledUsage.Model(
                model: model,
                provider: OpenCodeGoBilledUsage.billableProvider,
                requests: self.sum(rows.map(\.requests)),
                inputTokens: self.sum(rows.map(\.inputTokens)),
                outputTokens: self.sum(rows.map(\.outputTokens)),
                cacheReadTokens: self.sum(rows.map(\.cacheReadTokens)),
                cacheCreationTokens: self.sum(rows.map(\.cacheCreationTokens)),
                totalTokens: self.sum(rows.map(\.totalTokens)),
                costUSD: self.totalCost(rows.map(\.costUSD)))
        }
    }

    /// Totals only when every row carried a cost; an unpriced row must not read as a priced zero.
    private static func totalCost(_ values: [Double?]) -> Double? {
        guard !values.isEmpty, values.allSatisfy({ $0 != nil }) else { return nil }
        return values.compactMap(\.self).reduce(0, +)
    }
}
