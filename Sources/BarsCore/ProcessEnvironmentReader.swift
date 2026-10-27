import Foundation

/// Reads selected variables from another process's environment block.
enum ProcessEnvironmentReader {
    static let maxEnvironmentBytes = 1_048_576
    static func parseNULSeparated(
        _ data: Data,
        names: Set<String>) -> [String: String]?
    {
        guard data.count <= self.maxEnvironmentBytes,
              data.isEmpty || data.last == 0
        else { return nil }

        var selected: [String: String] = [:]
        // Byte-range search avoids walking large unrelated values through Data's generic split iterator.
        var remainder = data.drop(while: { $0 == 0 })
        while let end = remainder.range(of: Data([0]))?.lowerBound {
            let record = remainder[..<end]
            remainder = remainder[remainder.index(after: end)...].drop(while: { $0 == 0 })
            guard let separator = record.firstIndex(of: 61) else { return nil }
            guard let name = String(bytes: record[..<separator], encoding: .utf8),
                  names.contains(name)
            else { continue }
            let valueStart = record.index(after: separator)
            guard let value = String(bytes: record[valueStart...], encoding: .utf8) else { return nil }
            // Conflicting duplicate selectors cannot identify one process-owned root safely.
            if let previous = selected[name], previous != value { return nil }
            selected[name] = value
        }
        return selected
    }

    static func readLinuxEnvironment(
        pid: Int32,
        procRoot: URL = URL(fileURLWithPath: "/proc", isDirectory: true),
        names: Set<String>) -> [String: String]?
    {
        guard pid > 0 else { return nil }
        let url = procRoot
            .appendingPathComponent(String(pid), isDirectory: true)
            .appendingPathComponent("environ")
        guard let file = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? file.close() }

        do {
            var data = Data()
            while data.count <= self.maxEnvironmentBytes {
                let remaining = self.maxEnvironmentBytes + 1 - data.count
                let chunk = try file.read(upToCount: remaining) ?? Data()
                if chunk.isEmpty { return self.parseNULSeparated(data, names: names) }
                data.append(chunk)
            }
        } catch {
            return nil
        }
        return nil
    }
}
