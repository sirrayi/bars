import BarsCore
import Foundation

extension Notification.Name {
    static let barsDebugBlinkNow = Notification.Name("barsDebugBlinkNow")
    #if DEBUG
    static let barsDebugSimulateMemoryPressure =
        Notification.Name("com.sirrayi.bars.debug.simulateMemoryPressure")
    #endif
    static let barsSessionLimitReset = Notification.Name("barsSessionLimitReset")
    static let barsWeeklyLimitReset = Notification.Name("barsWeeklyLimitReset")
    static let barsProviderConfigDidChange = Notification.Name("barsProviderConfigDidChange")
    static let barsLocalConfigFileDidChange = Notification.Name("barsLocalConfigFileDidChange")
    static let barsQuotaWarningDidPost = Notification.Name("barsQuotaWarningDidPost")
}

@MainActor
final class SessionLimitResetEvent: NSObject {
    let provider: UsageProvider
    let accountIdentifier: String
    let accountLabel: String?
    let usedPercent: Double

    init(provider: UsageProvider, accountIdentifier: String, accountLabel: String?, usedPercent: Double) {
        self.provider = provider
        self.accountIdentifier = accountIdentifier
        self.accountLabel = accountLabel
        self.usedPercent = usedPercent
    }
}

@MainActor
final class WeeklyLimitResetEvent: NSObject {
    let provider: UsageProvider
    let accountIdentifier: String
    let accountLabel: String?
    let usedPercent: Double

    init(provider: UsageProvider, accountIdentifier: String, accountLabel: String?, usedPercent: Double) {
        self.provider = provider
        self.accountIdentifier = accountIdentifier
        self.accountLabel = accountLabel
        self.usedPercent = usedPercent
    }
}

@MainActor
final class QuotaWarningPostedEvent: NSObject {
    let provider: UsageProvider
    let window: QuotaWarningWindow
    let threshold: Int
    let postedAt: Date

    init(provider: UsageProvider, window: QuotaWarningWindow, threshold: Int, postedAt: Date) {
        self.provider = provider
        self.window = window
        self.threshold = threshold
        self.postedAt = postedAt
    }
}
