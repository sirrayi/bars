import Foundation

/// Portable preference values carried by exported preferences documents.
public struct SyncedPreferences: Codable, Sendable {
    public var statusChecksEnabled: Bool
    public var sessionQuotaNotificationsEnabled: Bool
    public var quotaWarningNotificationsEnabled: Bool
    public var predictivePaceWarningNotificationsEnabled: Bool
    public var quotaWarningThresholds: [Int]
    public var quotaWarningSessionThresholds: [Int]
    public var quotaWarningWeeklyThresholds: [Int]
    public var quotaWarningSessionEnabled: Bool
    public var quotaWarningWeeklyEnabled: Bool
    public var quotaWarningSoundEnabled: Bool
    public var quotaWarningOnScreenAlertEnabled: Bool
    public var quotaWarningMarkersVisible: Bool
    public var paceVisible: Bool?
    public var weeklyProgressWorkDays: Int?
    public var workdayTickAppearance: String?
    public var usageBarsShowUsed: Bool
    public var resetTimesShowAbsolute: Bool
    public var costUsageEnabled: Bool
    public var costComparisonPeriodsEnabled: Bool
    public var costSummaryDisplayStyle: String
    public var hidePersonalInfo: Bool
    public var randomBlinkEnabled: Bool
    public var confettiOnSessionLimitResetsEnabled: Bool
    public var confettiOnWeeklyLimitResetsEnabled: Bool
    public var menuBarShowsHighestUsage: Bool
    public var unifiedIconSource: String?
    public var showOptionalCreditsAndExtraUsage: Bool
    public var providerChangelogLinksEnabled: Bool
    public var preferredCurrencyCode: String
    public var providersSortedAlphabetically: Bool
    public var refreshFrequency: String
    public var refreshAllProvidersOnMenuOpen: Bool

    public init(
        statusChecksEnabled: Bool,
        sessionQuotaNotificationsEnabled: Bool,
        quotaWarningNotificationsEnabled: Bool,
        predictivePaceWarningNotificationsEnabled: Bool,
        quotaWarningThresholds: [Int],
        quotaWarningSessionThresholds: [Int],
        quotaWarningWeeklyThresholds: [Int],
        quotaWarningSessionEnabled: Bool,
        quotaWarningWeeklyEnabled: Bool,
        quotaWarningSoundEnabled: Bool,
        quotaWarningOnScreenAlertEnabled: Bool,
        quotaWarningMarkersVisible: Bool,
        paceVisible: Bool? = nil,
        weeklyProgressWorkDays: Int?,
        workdayTickAppearance: String? = nil,
        usageBarsShowUsed: Bool,
        resetTimesShowAbsolute: Bool,
        costUsageEnabled: Bool,
        costComparisonPeriodsEnabled: Bool,
        costSummaryDisplayStyle: String,
        hidePersonalInfo: Bool,
        randomBlinkEnabled: Bool,
        confettiOnSessionLimitResetsEnabled: Bool,
        confettiOnWeeklyLimitResetsEnabled: Bool,
        menuBarShowsHighestUsage: Bool,
        unifiedIconSource: String? = nil,
        showOptionalCreditsAndExtraUsage: Bool,
        providerChangelogLinksEnabled: Bool,
        preferredCurrencyCode: String,
        providersSortedAlphabetically: Bool,
        refreshFrequency: String,
        refreshAllProvidersOnMenuOpen: Bool)
    {
        self.statusChecksEnabled = statusChecksEnabled
        self.sessionQuotaNotificationsEnabled = sessionQuotaNotificationsEnabled
        self.quotaWarningNotificationsEnabled = quotaWarningNotificationsEnabled
        self.predictivePaceWarningNotificationsEnabled = predictivePaceWarningNotificationsEnabled
        self.quotaWarningThresholds = quotaWarningThresholds
        self.quotaWarningSessionThresholds = quotaWarningSessionThresholds
        self.quotaWarningWeeklyThresholds = quotaWarningWeeklyThresholds
        self.quotaWarningSessionEnabled = quotaWarningSessionEnabled
        self.quotaWarningWeeklyEnabled = quotaWarningWeeklyEnabled
        self.quotaWarningSoundEnabled = quotaWarningSoundEnabled
        self.quotaWarningOnScreenAlertEnabled = quotaWarningOnScreenAlertEnabled
        self.quotaWarningMarkersVisible = quotaWarningMarkersVisible
        self.paceVisible = paceVisible
        self.weeklyProgressWorkDays = weeklyProgressWorkDays
        self.workdayTickAppearance = workdayTickAppearance
        self.usageBarsShowUsed = usageBarsShowUsed
        self.resetTimesShowAbsolute = resetTimesShowAbsolute
        self.costUsageEnabled = costUsageEnabled
        self.costComparisonPeriodsEnabled = costComparisonPeriodsEnabled
        self.costSummaryDisplayStyle = costSummaryDisplayStyle
        self.hidePersonalInfo = hidePersonalInfo
        self.randomBlinkEnabled = randomBlinkEnabled
        self.confettiOnSessionLimitResetsEnabled = confettiOnSessionLimitResetsEnabled
        self.confettiOnWeeklyLimitResetsEnabled = confettiOnWeeklyLimitResetsEnabled
        self.menuBarShowsHighestUsage = menuBarShowsHighestUsage
        self.unifiedIconSource = unifiedIconSource
        self.showOptionalCreditsAndExtraUsage = showOptionalCreditsAndExtraUsage
        self.providerChangelogLinksEnabled = providerChangelogLinksEnabled
        self.preferredCurrencyCode = preferredCurrencyCode
        self.providersSortedAlphabetically = providersSortedAlphabetically
        self.refreshFrequency = refreshFrequency
        self.refreshAllProvidersOnMenuOpen = refreshAllProvidersOnMenuOpen
    }
}
