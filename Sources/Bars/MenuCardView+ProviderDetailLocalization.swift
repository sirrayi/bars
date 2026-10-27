import BarsCore
import Foundation

extension UsageMenuCardView.Model {
    static func localizedProviderDetails(
        _ details: [ProviderDetailSection],
        provider: UsageProvider) -> [ProviderDetailSection]
    {
        // Provider-specific by design: DeepSeek rewrites value phrasing.
        // Other providers localize section titles and row labels through the shared catalog; values stay canonical.
        guard provider == .deepseek else {
            return details.compactMap { section in
                let rows = section.rows.compactMap { row in
                    try? ProviderDetailSection.Row(
                        id: row.id,
                        label: L(row.label),
                        value: row.value,
                        secondaryValue: self.localizedProviderDetailSecondaryValue(row, provider: provider),
                        progress: row.progress,
                        severity: row.severity,
                        usageValue: row.usageValue)
                }
                return try? ProviderDetailSection(
                    title: section.title.map(L),
                    rows: rows,
                    chart: section.chart)
            }
        }
        return details.compactMap { section in
            let rows = section.rows.compactMap { row in
                try? ProviderDetailSection.Row(
                    id: row.id,
                    label: L(row.label),
                    value: self.localizedProviderDetailValue(row.value, provider: provider),
                    secondaryValue: row.secondaryValue.map {
                        self.localizedProviderDetailValue($0, provider: provider)
                    },
                    progress: row.progress,
                    severity: row.severity,
                    usageValue: row.usageValue)
            }
            let chart = section.chart.flatMap { chart in
                try? ProviderDetailSection.Chart(
                    kind: chart.kind,
                    title: chart.title.map(L),
                    unit: chart.unit.map(L),
                    points: chart.points)
            }
            return try? ProviderDetailSection(
                title: section.title.map(L),
                rows: rows,
                chart: chart)
        }
    }

    private static func localizedProviderDetailSecondaryValue(
        _ row: ProviderDetailSection.Row,
        provider: UsageProvider) -> String?
    {
        row.secondaryValue
    }

    static func localizedDeepSeekBalanceDescription(_ description: String) -> String {
        let unavailable = "Balance unavailable for API calls"
        if description == unavailable {
            return L(unavailable)
        }

        let addCreditsSeparator = " — add credits at "
        if let range = description.range(of: addCreditsSeparator) {
            return L(
                "%@ — add credits at %@",
                String(description[..<range.lowerBound]),
                String(description[range.upperBound...]))
        }

        let paidSeparator = " (Paid: "
        let grantedSeparator = " / Granted: "
        guard let paidRange = description.range(of: paidSeparator),
              let grantedRange = description.range(
                  of: grantedSeparator,
                  range: paidRange.upperBound..<description.endIndex),
              description.last == ")"
        else {
            return description
        }

        let total = String(description[..<paidRange.lowerBound])
        let paid = String(description[paidRange.upperBound..<grantedRange.lowerBound])
        let granted = String(description[grantedRange.upperBound..<description.index(before: description.endIndex)])
        return L("%@ (Paid: %@ / Granted: %@)", total, paid, granted)
    }

    static func localizedZaiPeriodicResetText(_ window: RateWindow) -> String? {
        guard window.resetsAt == nil,
              window.resetDescription?.trimmingCharacters(in: .whitespacesAndNewlines) == "5-hour"
        else {
            return nil
        }
        return L("Resets every 5 hours")
    }

    /// Provider-specific by design: DeepSeek, z.ai, Kiro, and Grok detail values carry provider-owned
    /// unit phrasing that localizes at the presentation boundary without touching other providers.
    private static func localizedProviderDetailValue(_ value: String, provider: UsageProvider) -> String {
        switch provider {
        case .deepseek:
            self.localizedTokenSuffix(value)
        default:
            value
        }
    }

    private static func localizedTokenSuffix(_ value: String) -> String {
        let suffix = " tokens"
        guard value.hasSuffix(suffix) else { return value }
        return L("%@ tokens", String(value.dropLast(suffix.count)))
    }

    private static func localizedZaiCountdown(_ value: String) -> String {
        guard value.hasPrefix("in ") else { return L(value) }
        let parts = value.dropFirst(3).split(separator: " ").map(String.init)
        if parts.count == 2 {
            let first = parts[0]
            let second = parts[1]
            if first.hasSuffix("d"), second.hasSuffix("h") {
                return L("in %@d %@h", String(first.dropLast()), String(second.dropLast()))
            }
            if first.hasSuffix("d"), second.hasSuffix("m") {
                return L("in %@d %@m", String(first.dropLast()), String(second.dropLast()))
            }
            if first.hasSuffix("h"), second.hasSuffix("m") {
                return L("in %@h %@m", String(first.dropLast()), String(second.dropLast()))
            }
        }
        if parts.count == 1 {
            let part = parts[0]
            if part.hasSuffix("d") {
                return L("in %@d", String(part.dropLast()))
            }
            if part.hasSuffix("h") {
                return L("in %@h", String(part.dropLast()))
            }
            if part.hasSuffix("m") {
                return L("in %@m", String(part.dropLast()))
            }
        }
        return value
    }
}
