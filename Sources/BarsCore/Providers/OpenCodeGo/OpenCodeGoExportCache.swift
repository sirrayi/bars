import Foundation

/// Short-lived cache for the Console's per-day usage export.
///
/// The export is the expensive Console read: it aggregates the whole billing window server-side and
/// takes about a second to answer even though the payload is only a couple of kilobytes. Billed spend
/// and token counts move far more slowly than the quota meters, so a repeated refresh inside the
/// freshness window reuses the parsed text instead of paying that second again.
///
/// Only the raw CSV is cached — never credentials or account columns — and the quota percentages keep
/// coming from the live meters read, so a stale entry can never delay a reset.
struct OpenCodeGoExportCache: @unchecked Sendable {
    /// Billed history older than this is re-fetched. Quota is unaffected.
    static let maximumAge: TimeInterval = 180

    let root: URL
    let maximumAge: TimeInterval
    private let fileManager: FileManager

    init(
        root: URL = OpenCodeGoExportCache.defaultRoot(),
        maximumAge: TimeInterval = OpenCodeGoExportCache.maximumAge,
        fileManager: FileManager = .default)
    {
        self.root = root
        self.maximumAge = maximumAge
        self.fileManager = fileManager
    }

    static func defaultRoot(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return base
            .appendingPathComponent("bars", isDirectory: true)
            .appendingPathComponent("opencodego-export", isDirectory: true)
    }

    /// Returns the cached export text when it is younger than `maximumAge`.
    func load(range: String, now: Date = Date()) -> String? {
        let url = self.url(for: range)
        guard let attributes = try? self.fileManager.attributesOfItem(atPath: url.path),
              let modified = attributes[.modificationDate] as? Date,
              now.timeIntervalSince(modified) < self.maximumAge
        else {
            return nil
        }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// Best effort: a cache that cannot be written must never fail the fetch.
    func store(_ text: String, range: String) {
        let url = self.url(for: range)
        try? self.fileManager.createDirectory(
            at: self.root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try? Data(text.utf8).write(to: url, options: .atomic)
    }

    private func url(for range: String) -> URL {
        self.root.appendingPathComponent("usage-\(range).csv", isDirectory: false)
    }
}
