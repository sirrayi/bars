import Foundation

#if canImport(SQLite3)
import SQLite3
#elseif canImport(CSQLite3)
import CSQLite3
#endif

public enum DevinLocalCostError: LocalizedError, Sendable, Equatable {
    case sqliteFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .sqliteFailed(message):
            "SQLite error reading Devin CLI usage: \(message)"
        }
    }
}

/// How a Devin CLI `generation_model` value maps to a pricing source.
public enum DevinPricingRoute: Sendable, Equatable {
    /// SWE-2 models and the compactor are free during Devin's promo.
    case free
    /// A Claude model, possibly carrying a Devin effort suffix; the payload is the normalized model ID.
    case claude(String)
    /// Anything else stays unpriced; the rate is never guessed.
    case unknown
}

public struct DevinLocalCostReader: Sendable {
    private let databaseURL: URL

    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.databaseURL = homeDirectory
            .appendingPathComponent(".local/share/devin/cli/sessions.db", isDirectory: false)
    }

    public init(databaseURL: URL) {
        self.databaseURL = databaseURL
    }

    private static let effortSuffixes = ["-low", "-medium", "-high", "-xhigh", "-max"]
    private static let claudeModelID = try? NSRegularExpression(
        pattern: #"^claude-(?:opus|sonnet|haiku)-\d+-\d+(?:-\d+)*$"#)

    /// Route a raw `generation_model` (for example `claude-sonnet-5-5-xhigh`) to its pricing source.
    /// Devin appends an effort suffix to Claude IDs; numeric suffixes (snapshot dates) stay attached
    /// because the shared Claude pricer normalizes them itself.
    public static func pricingRoute(for generationModel: String) -> DevinPricingRoute {
        let model = generationModel.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !model.isEmpty else { return .unknown }
        if model.hasPrefix("swe-") || model == "compactor" { return .free }
        var candidate = model
        for suffix in self.effortSuffixes where candidate.hasSuffix(suffix) {
            candidate = String(candidate.dropLast(suffix.count))
            break
        }
        guard let expression = self.claudeModelID,
              expression.firstMatch(
                  in: candidate,
                  range: NSRange(candidate.startIndex..., in: candidate)) != nil
        else { return .unknown }
        return .claude(candidate)
    }

    // Aggregate deduplicated requests into local-day entries. Returns nil when the Devin CLI
    // database does not exist; SQLite failures throw.
    // swiftlint:disable:next function_parameter_count
    func makeDailyReport(
        since: Date,
        until: Date,
        calendar: Calendar,
        catalog: ModelsDevCatalog?,
        modelsDevCacheRoot: URL?,
        customPricing: CostUsageCustomPricing) throws -> CostUsageDailyReport?
    {
        guard FileManager.default.fileExists(atPath: self.databaseURL.path) else { return nil }
        let requests = try self.readRequests(since: since, until: until)
        var days: [String: DayAccumulator] = [:]
        for request in requests {
            let date = Date(timeIntervalSince1970: TimeInterval(request.createdAt))
            let key = CostUsageLocalDay.key(from: date, calendar: calendar)
            days[key, default: DayAccumulator()].add(
                request: request,
                costUSD: self.requestCostUSD(
                    request: request,
                    pricingDate: date,
                    catalog: catalog,
                    modelsDevCacheRoot: modelsDevCacheRoot,
                    customPricing: customPricing))
        }
        let entries = days.map { key, day in
            day.entry(date: key)
        }
        .sorted { $0.date < $1.date }
        return CostUsageDailyReport(data: entries, summary: nil)
    }

    private func requestCostUSD(
        request: RequestRow,
        pricingDate: Date,
        catalog: ModelsDevCatalog?,
        modelsDevCacheRoot: URL?,
        customPricing: CostUsageCustomPricing) -> Double?
    {
        let tokens = request.tokens
        if let cost = customPricing.costUSD(
            providerID: "devin",
            model: request.model,
            inputTokens: tokens.input,
            outputTokens: tokens.output,
            cacheReadTokens: tokens.cacheRead,
            cacheWriteTokens: tokens.cacheCreation)
        {
            return cost
        }
        switch Self.pricingRoute(for: request.model) {
        case .free:
            return 0
        case let .claude(normalized):
            if normalized != request.model,
               let cost = customPricing.costUSD(
                   providerID: "devin",
                   model: normalized,
                   inputTokens: tokens.input,
                   outputTokens: tokens.output,
                   cacheReadTokens: tokens.cacheRead,
                   cacheWriteTokens: tokens.cacheCreation)
            {
                return cost
            }
            return CostUsagePricing.claudeCostUSD(
                model: normalized,
                inputTokens: tokens.input,
                cacheReadInputTokens: tokens.cacheRead,
                cacheCreationInputTokens: tokens.cacheCreation,
                outputTokens: tokens.output,
                pricingDate: pricingDate,
                modelsDevCatalog: catalog,
                modelsDevCacheRoot: modelsDevCacheRoot)
        case .unknown:
            return nil
        }
    }

    private func readRequests(since: Date, until: Date) throws -> [RequestRow] {
        do {
            return try self.readRequests(since: since, until: until, immutable: false)
        } catch let failure as SQLiteReadFailure {
            // A clean WAL shutdown can remove both sidecars while leaving the database header in
            // WAL mode. Immutable mode reads that idle main file without recreating sidecars.
            guard failure.code == SQLITE_CANTOPEN, self.walSidecarsAreMissing else {
                throw DevinLocalCostError.sqliteFailed(failure.message)
            }
            do {
                return try self.readRequests(since: since, until: until, immutable: true)
            } catch let fallbackFailure as SQLiteReadFailure {
                throw DevinLocalCostError.sqliteFailed(fallbackFailure.message)
            }
        }
    }

    private func readRequests(since: Date, until: Date, immutable: Bool) throws -> [RequestRow] {
        var db: OpaquePointer?
        let filename = immutable ? "\(self.databaseURL.absoluteURL.absoluteString)?immutable=1" : self.databaseURL.path
        let flags = immutable ? SQLITE_OPEN_READONLY | SQLITE_OPEN_URI : SQLITE_OPEN_READONLY
        let openResult = sqlite3_open_v2(filename, &db, flags, nil)
        guard openResult == SQLITE_OK else {
            let failure = Self.sqliteFailure(db: db, resultCode: openResult)
            sqlite3_close(db)
            throw failure
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 250)

        guard try Self.hasTable(named: "message_nodes", db: db) else {
            throw Self.sqliteFailure(db: db, resultCode: SQLITE_ERROR)
        }

        // The CLI re-inserts the same response as several nodes sharing one `request_id` with
        // identical metrics, so group on the request key and take the earliest timestamp. Filtering
        // on `created_at` before grouping would count an old request re-copied inside the window.
        let sql = """
        SELECT MIN(created_at), MAX(model), MAX(i), MAX(o), MAX(cr), MAX(cw) FROM (
          SELECT created_at,
            COALESCE(json_extract(chat_message, '$.metadata.request_id'), 'row:' || row_id) AS request_key,
            COALESCE(json_extract(chat_message, '$.metadata.generation_model'), '') AS model,
            COALESCE(json_extract(chat_message, '$.metadata.metrics.input_tokens'), 0) AS i,
            COALESCE(json_extract(chat_message, '$.metadata.metrics.output_tokens'), 0) AS o,
            COALESCE(json_extract(chat_message, '$.metadata.metrics.cache_read_tokens'), 0) AS cr,
            COALESCE(json_extract(chat_message, '$.metadata.metrics.cache_creation_tokens'), 0) AS cw
          FROM message_nodes
          WHERE json_valid(chat_message)
            AND json_type(chat_message, '$.metadata.metrics') = 'object'
        ) GROUP BY request_key
        HAVING MIN(created_at) >= ?1 AND MIN(created_at) <= ?2
        """

        var stmt: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard prepareResult == SQLITE_OK else {
            throw Self.sqliteFailure(db: db, resultCode: prepareResult)
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, Int64(since.timeIntervalSince1970))
        sqlite3_bind_int64(stmt, 2, Int64(until.timeIntervalSince1970))

        var rows: [RequestRow] = []
        var step = sqlite3_step(stmt)
        while step == SQLITE_ROW {
            defer { step = sqlite3_step(stmt) }
            let createdAt = sqlite3_column_int64(stmt, 0)
            let model = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            rows.append(RequestRow(
                createdAt: createdAt,
                model: model,
                tokens: .init(
                    input: Self.tokenCount(sqlite3_column_int64(stmt, 2)),
                    output: Self.tokenCount(sqlite3_column_int64(stmt, 3)),
                    cacheRead: Self.tokenCount(sqlite3_column_int64(stmt, 4)),
                    cacheCreation: Self.tokenCount(sqlite3_column_int64(stmt, 5)))))
        }
        guard step == SQLITE_DONE else { throw Self.sqliteFailure(db: db, resultCode: step) }
        return rows
    }

    private static func tokenCount(_ value: Int64) -> Int {
        value > 0 ? Int(clamping: value) : 0
    }

    private var walSidecarsAreMissing: Bool {
        !FileManager.default.fileExists(atPath: self.databaseURL.path + "-wal") &&
            !FileManager.default.fileExists(atPath: self.databaseURL.path + "-shm")
    }

    private static func sqliteFailure(db: OpaquePointer?, resultCode: Int32) -> SQLiteReadFailure {
        SQLiteReadFailure(
            code: db.map { sqlite3_errcode($0) } ?? resultCode,
            message: db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error")
    }

    private static func hasTable(named name: String, db: OpaquePointer?) throws -> Bool {
        let result = sqlite3_table_column_metadata(db, nil, name, nil, nil, nil, nil, nil, nil)
        switch result {
        case SQLITE_OK: return true
        case SQLITE_ERROR: return false
        default: throw Self.sqliteFailure(db: db, resultCode: result)
        }
    }

    private struct SQLiteReadFailure: Error {
        let code: Int32
        let message: String
    }

    private struct RequestRow {
        struct Tokens {
            let input: Int
            let output: Int
            let cacheRead: Int
            let cacheCreation: Int
        }

        let createdAt: Int64
        /// Raw `generation_model`; empty when unattributed.
        let model: String
        let tokens: Tokens
    }

    private struct DayAccumulator {
        struct ModelAccumulator {
            var input = 0
            var output = 0
            var cacheRead = 0
            var cacheCreation = 0
            var requestCount = 0
            var costUSD: Double?
            var pricedRequestCount = 0

            mutating func add(request: RequestRow, costUSD: Double?) {
                self.input += request.tokens.input
                self.output += request.tokens.output
                self.cacheRead += request.tokens.cacheRead
                self.cacheCreation += request.tokens.cacheCreation
                self.requestCount += 1
                if let costUSD {
                    self.costUSD = (self.costUSD ?? 0) + costUSD
                    self.pricedRequestCount += 1
                }
            }

            var totalTokens: Int? {
                CheckedSum.integers([self.input, self.output, self.cacheRead, self.cacheCreation])
            }
        }

        var input = 0
        var output = 0
        var cacheRead = 0
        var cacheCreation = 0
        var requestCount = 0
        var costUSD: Double?
        var pricedRequestCount = 0
        var unpricedRequestCount = 0
        var models: [String: ModelAccumulator] = [:]

        mutating func add(request: RequestRow, costUSD: Double?) {
            self.input += request.tokens.input
            self.output += request.tokens.output
            self.cacheRead += request.tokens.cacheRead
            self.cacheCreation += request.tokens.cacheCreation
            self.requestCount += 1
            if let costUSD {
                self.costUSD = (self.costUSD ?? 0) + costUSD
                self.pricedRequestCount += 1
            } else {
                self.unpricedRequestCount += 1
            }
            let model = request.model.trimmingCharacters(in: .whitespacesAndNewlines)
            self.models[model.isEmpty ? "unknown" : model, default: ModelAccumulator()]
                .add(request: request, costUSD: costUSD)
        }

        func entry(date: String) -> CostUsageDailyReport.Entry {
            let breakdowns = self.models
                .map { model, totals in
                    CostUsageDailyReport.ModelBreakdown(
                        modelName: model,
                        costUSD: totals.costUSD,
                        totalTokens: totals.totalTokens,
                        requestCount: totals.requestCount,
                        inputTokens: totals.input,
                        outputTokens: totals.output,
                        cacheReadTokens: totals.cacheRead,
                        cacheCreationTokens: totals.cacheCreation)
                }
                .sorted { lhs, rhs in
                    let lhsCost = lhs.costUSD ?? -.greatestFiniteMagnitude
                    let rhsCost = rhs.costUSD ?? -.greatestFiniteMagnitude
                    if lhsCost != rhsCost { return lhsCost > rhsCost }
                    return (lhs.totalTokens ?? 0) > (rhs.totalTokens ?? 0)
                }
            return CostUsageDailyReport.Entry(
                date: date,
                inputTokens: self.input,
                outputTokens: self.output,
                cacheReadTokens: self.cacheRead,
                cacheCreationTokens: self.cacheCreation,
                totalTokens: CheckedSum
                    .integers([self.input, self.output, self.cacheRead, self.cacheCreation]),
                requestCount: self.requestCount,
                costUSD: self.costUSD,
                modelsUsed: breakdowns.map(\.modelName),
                modelBreakdowns: breakdowns,
                unpricedRequestCount: self.unpricedRequestCount,
                pricedRequestCount: self.pricedRequestCount)
        }
    }
}
