import Foundation

public enum TextParsing {
    /// Lowercases and dash-joins a display name into an identifier fragment. Two Claude parsers had
    /// byte-identical copies of this.
    static func slug(_ value: String) -> String {
        var result = ""
        var lastWasDash = false
        for scalar in value.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                result.unicodeScalars.append(scalar)
                lastWasDash = false
            } else if !lastWasDash {
                result.append("-")
                lastWasDash = true
            }
        }
        return result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    /// Whether `pattern` matches anywhere in `text`. Two OpenCode parsers carried identical copies.
    static func containsMatch(pattern: String, text: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return false }
        let nsrange = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.firstMatch(in: text, options: [], range: nsrange) != nil
    }

    /// Removes ANSI escape sequences so regex parsing works on colored terminal output.
    public static func stripANSICodes(_ text: String) -> String {
        // CSI sequences: ESC [ ... ending in 0x40–0x7E
        let pattern = #"\u001B\[[0-?]*[ -/]*[@-~]"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "")
    }

    public static func firstNumber(pattern: String, text: String) -> Double? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges >= 2,
              let r = Range(match.range(at: 1), in: text) else { return nil }
        let raw = String(text[r])
        return Self.parseNumber(raw)
    }

    private static func parseNumber(_ raw: String) -> Double? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        text = text.replacingOccurrences(of: "\u{00A0}", with: "")
        text = text.replacingOccurrences(of: "\u{202F}", with: "")
        text = text.replacingOccurrences(of: " ", with: "")

        let hasComma = text.contains(",")
        let hasDot = text.contains(".")

        if hasComma, hasDot {
            if let lastComma = text.lastIndex(of: ","), let lastDot = text.lastIndex(of: ".") {
                if lastComma > lastDot {
                    text = text.replacingOccurrences(of: ".", with: "")
                    text = text.replacingOccurrences(of: ",", with: ".")
                } else {
                    text = text.replacingOccurrences(of: ",", with: "")
                }
            }
        } else if hasComma {
            if text.range(of: #"^\d{1,3}(,\d{3})+$"#, options: .regularExpression) != nil {
                text = text.replacingOccurrences(of: ",", with: "")
            } else {
                text = text.replacingOccurrences(of: ",", with: ".")
            }
        } else if hasDot {
            if text.range(of: #"^\d{1,3}(\.\d{3})+$"#, options: .regularExpression) != nil {
                text = text.replacingOccurrences(of: ".", with: "")
            }
        }

        return Double(text)
    }

    public static func firstInt(pattern: String, text: String) -> Int? {
        guard let v = firstNumber(pattern: pattern, text: text) else { return nil }
        return Int(v)
    }

    public static func firstLine(matching pattern: String, text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              let r = Range(match.range(at: 0), in: text) else { return nil }
        return String(text[r])
    }

    public static func percentLeft(fromLine line: String) -> Int? {
        guard let pct = firstInt(pattern: #"([0-9]{1,3})%\s+left"#, text: line) else { return nil }
        return pct
    }
}
