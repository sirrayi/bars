import BarsCore
import Foundation

extension SettingsStore {
    var syncedPreferences: SyncedPreferences {
        SyncedPreferences(
            statusChecksEnabled: self.statusChecksEnabled,
            sessionQuotaNotificationsEnabled: self.sessionQuotaNotificationsEnabled,
            quotaWarningNotificationsEnabled: self.quotaWarningNotificationsEnabled,
            predictivePaceWarningNotificationsEnabled: self.predictivePaceWarningNotificationsEnabled,
            quotaWarningThresholds: self.quotaWarningThresholds,
            quotaWarningSessionThresholds: self.quotaWarningThresholds(.session),
            quotaWarningWeeklyThresholds: self.quotaWarningThresholds(.weekly),
            quotaWarningSessionEnabled: self.quotaWarningWindowEnabled(.session),
            quotaWarningWeeklyEnabled: self.quotaWarningWindowEnabled(.weekly),
            quotaWarningSoundEnabled: self.quotaWarningSoundEnabled,
            quotaWarningOnScreenAlertEnabled: self.quotaWarningOnScreenAlertEnabled,
            quotaWarningMarkersVisible: self.quotaWarningMarkersVisible,
            paceVisible: self.paceVisible,
            weeklyProgressWorkDays: self.weeklyProgressWorkDays,
            workdayTickAppearance: self.workdayTickAppearance.rawValue,
            usageBarsShowUsed: self.usageBarsShowUsed,
            resetTimesShowAbsolute: self.resetTimesShowAbsolute,
            costUsageEnabled: self.costUsageEnabled,
            costComparisonPeriodsEnabled: self.costComparisonPeriodsEnabled,
            costSummaryDisplayStyle: self.costSummaryDisplayStyleRaw,
            hidePersonalInfo: self.hidePersonalInfo,
            randomBlinkEnabled: self.randomBlinkEnabled,
            confettiOnSessionLimitResetsEnabled: self.confettiOnSessionLimitResetsEnabled,
            confettiOnWeeklyLimitResetsEnabled: self.confettiOnWeeklyLimitResetsEnabled,
            menuBarShowsHighestUsage: self.menuBarShowsHighestUsage,
            unifiedIconSource: self.unifiedIconSource.rawValue,
            showOptionalCreditsAndExtraUsage: self.showOptionalCreditsAndExtraUsage,
            providerChangelogLinksEnabled: self.providerChangelogLinksEnabled,
            preferredCurrencyCode: self.preferredCurrencyCode,
            providersSortedAlphabetically: self.providersSortedAlphabetically,
            refreshFrequency: self.refreshFrequency.rawValue,
            refreshAllProvidersOnMenuOpen: self.refreshAllProvidersOnMenuOpen)
    }

    func applySyncedPreferences(_ preferences: SyncedPreferences) {
        self.statusChecksEnabled = preferences.statusChecksEnabled
        self.sessionQuotaNotificationsEnabled = preferences.sessionQuotaNotificationsEnabled
        self.quotaWarningNotificationsEnabled = preferences.quotaWarningNotificationsEnabled
        self.predictivePaceWarningNotificationsEnabled = preferences.predictivePaceWarningNotificationsEnabled
        self.quotaWarningThresholds = preferences.quotaWarningThresholds
        self.setQuotaWarningThresholds(.session, thresholds: preferences.quotaWarningSessionThresholds)
        self.setQuotaWarningThresholds(.weekly, thresholds: preferences.quotaWarningWeeklyThresholds)
        self.setQuotaWarningWindowEnabled(.session, enabled: preferences.quotaWarningSessionEnabled)
        self.setQuotaWarningWindowEnabled(.weekly, enabled: preferences.quotaWarningWeeklyEnabled)
        self.quotaWarningSoundEnabled = preferences.quotaWarningSoundEnabled
        self.quotaWarningOnScreenAlertEnabled = preferences.quotaWarningOnScreenAlertEnabled
        self.quotaWarningMarkersVisible = preferences.quotaWarningMarkersVisible
        if let paceVisible = preferences.paceVisible {
            self.paceVisible = paceVisible
        }
        self.weeklyProgressWorkDays = preferences.weeklyProgressWorkDays
        if let rawAppearance = preferences.workdayTickAppearance,
           let appearance = WorkdayTickAppearance(rawValue: rawAppearance)
        {
            self.workdayTickAppearance = appearance
        }
        self.usageBarsShowUsed = preferences.usageBarsShowUsed
        self.resetTimesShowAbsolute = preferences.resetTimesShowAbsolute
        self.costUsageEnabled = preferences.costUsageEnabled
        self.costComparisonPeriodsEnabled = preferences.costComparisonPeriodsEnabled
        self.costSummaryDisplayStyleRaw = preferences.costSummaryDisplayStyle
        self.hidePersonalInfo = preferences.hidePersonalInfo
        self.randomBlinkEnabled = preferences.randomBlinkEnabled
        self.confettiOnSessionLimitResetsEnabled = preferences.confettiOnSessionLimitResetsEnabled
        self.confettiOnWeeklyLimitResetsEnabled = preferences.confettiOnWeeklyLimitResetsEnabled
        self.unifiedIconSource = preferences.unifiedIconSource.flatMap(UnifiedIconSource.init(rawValue:))
            ?? (preferences.menuBarShowsHighestUsage ? .highestUsage : .currentSelection)
        self.showOptionalCreditsAndExtraUsage = preferences.showOptionalCreditsAndExtraUsage
        self.providerChangelogLinksEnabled = preferences.providerChangelogLinksEnabled
        self.preferredCurrencyCode = preferences.preferredCurrencyCode
        self.providersSortedAlphabetically = preferences.providersSortedAlphabetically
        if let refreshFrequency = RefreshFrequency(rawValue: preferences.refreshFrequency) {
            self.refreshFrequency = refreshFrequency
        }
        self.refreshAllProvidersOnMenuOpen = preferences.refreshAllProvidersOnMenuOpen
    }
}
