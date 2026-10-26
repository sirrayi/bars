import Foundation
@testable import CodexBarCore

/// Convenience defaults for synthetic cache fixtures. Production calls the value initializer directly.
extension CostUsageScanner {
    static func makeFileUsage(
        mtimeUnixMs: Int64,
        size: Int64,
        days: [String: [String: [Int]]],
        parsedBytes: Int64?,
        claudeRows: [ClaudeUsageRow]? = nil) -> CostUsageFileUsage
    {
        CostUsageFileUsage(
            mtimeUnixMs: mtimeUnixMs,
            size: size,
            days: days,
            parsedBytes: parsedBytes,
            claudeRows: claudeRows)
    }
}
