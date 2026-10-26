import CodexBarCore
import Foundation
import Testing
@testable import CodexBarWidget

struct BurnDownCapabilityTests {
    @Test
    func `every built in provider has a stable burn down intent case`() {
        #expect(Set(BurnProviderChoice.allCases.map(\.rawValue)) == Set(UsageProvider.allCases.map(\.rawValue)))
    }

    @Test
    func `unknown duration or reset never fabricates a burn down`() throws {
        let window = RateWindow(usedPercent: 20, windowMinutes: 300, resetsAt: nil, resetDescription: nil)
        let snapshot = Self.snapshot(provider: .claude, primary: window)
        let state = try #require(BurnDownState(snapshot: snapshot, provider: .claude, selection: .session))
        #expect(state.selectedWindow == nil)
    }

    @Test
    func `legacy intent aliases stay exact when new provider window shapes become available`() throws {
        for provider in [UsageProvider.claude] {
            let snapshot = Self.snapshot(provider: provider, primary: Self.window(minutes: 1440))
            let state = try #require(BurnDownState(snapshot: snapshot, provider: provider, selection: .session))
            #expect(state.selectedWindow == nil)
            #expect(state.window(for: .weekly) == nil)
            #expect(state.availableSelections == [.primary])
            #expect(state.window(for: .primary)?.windowMinutes == 1440)
            #expect(state.combinedSelections == [.primary, .secondary])

            let capped = try #require(BurnDownState(
                snapshot: Self.snapshot(
                    provider: provider,
                    primary: Self.window(minutes: 1440),
                    secondary: Self.window(minutes: 10080, used: 100)),
                provider: provider,
                selection: .primary,
                now: Date(timeIntervalSince1970: 1_700_000_000)))
            #expect(capped.selectedWindow?.remainingPercent == 0)
            #expect(capped.blankPrimaryChart)
            #expect(capped.selectedResetOverride == capped.secondaryWindow?.resetsAt)
        }
    }

    @Test
    func `capability filter rejects incomplete nonfinite and placeholder quotas`() {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let invalid: [RateWindow?] = [
            nil,
            Self.window(minutes: nil), Self.window(minutes: 0), Self.window(minutes: -1),
            Self.window(minutes: 1440, used: .nan), Self.window(minutes: 1440, used: .infinity),
            RateWindow(usedPercent: 10, windowMinutes: 1440, resetsAt: nil, resetDescription: nil),
            RateWindow(
                usedPercent: 10,
                windowMinutes: 1440,
                resetsAt: Date(timeIntervalSince1970: .infinity),
                resetDescription: nil),
            RateWindow(
                usedPercent: 0,
                windowMinutes: 300,
                resetsAt: date,
                resetDescription: nil,
                isSyntheticPlaceholder: true),
        ]
        for window in invalid {
            #expect(!BurnDownState.isCompatible(window))
            #expect(BurnProviderOptions.choices(in: Self.snapshot(provider: .devin, primary: window)).isEmpty)
        }
        // Real zero usage, over-quota usage, and expired but still dated measurements remain valid.
        #expect(BurnDownState.isCompatible(Self.window(minutes: 1440, used: 0)))
        #expect(BurnDownState.isCompatible(Self.window(minutes: 1440, used: 125)))
        #expect(BurnDownState.isCompatible(RateWindow(
            usedPercent: 10, windowMinutes: 1440, resetsAt: .distantPast, resetDescription: nil)))
    }

    @Test
    func `Devin daily and weekly keep their duration titles and lane identities`() throws {
        let daily = Self.window(minutes: 1440)
        let weekly = Self.window(minutes: 10080)
        let snapshot = Self.snapshot(provider: .devin, primary: daily, secondary: weekly)
        let state = try #require(BurnDownState(snapshot: snapshot, provider: .devin, selection: .primary))
        #expect(state.availableSelections == [.primary, .secondary])
        #expect(state.selectedTitle == "Daily")
        #expect(state.selectedWindow == daily)
        #expect(state.title(for: .secondary) == "Weekly")
        #expect(state.window(for: .secondary) == weekly)
        #expect(state.combinedSelections == [.primary, .secondary])
        #expect(burnCompactWindowLabel(1440, fallback: "") == "24H")
        #expect(burnCompactWindowLabel(10080, fallback: "") == "7D")
        #expect(!state.blankPrimaryChart)

        let missing = try #require(BurnDownState(
            snapshot: Self.snapshot(provider: .devin, primary: nil, secondary: weekly),
            provider: .devin,
            selection: .primary))
        #expect(missing.selectedWindow == nil)
        #expect(missing.combinedSelections == state.combinedSelections)
        #expect(missing.title(for: .primary) == "Daily")
        #expect(missing.window(for: .secondary) == weekly)
    }

    @Test
    func `saved legacy provider and window values keep parameter types defaults and meaning`() throws {
        let legacy = Data(#"[{"provider":"claude","window":"session"},{"provider":"claude","window":"weekly"}]"#.utf8)
        let values = try JSONDecoder().decode([[String: String]].self, from: legacy)
        for value in values {
            let providerRaw = try #require(value["provider"])
            let windowRaw = try #require(value["window"])
            let intent = BurnDownSelectionIntent()
            intent.provider = try #require(BurnProviderChoice(rawValue: providerRaw))
            intent.window = try #require(BurnWindowChoice(rawValue: windowRaw))
            let provider: BurnProviderChoice = intent.provider
            let selection: BurnWindowChoice = intent.window
            #expect(provider.rawValue == value["provider"])
            #expect(selection.rawValue == value["window"])
            let snapshot = Self.snapshot(
                provider: provider.provider,
                primary: Self.window(minutes: 300),
                secondary: Self.window(minutes: 10080))
            let state = try #require(BurnDownState(
                snapshot: snapshot, provider: provider.provider, selection: selection))
            #expect(state.selectedWindow?.windowMinutes == (selection == .session ? 300 : 10080))
            #expect(state.combinedSelections == [.session, .weekly])
        }
        #expect(BurnDownSelectionIntent().provider == .claude)
        #expect(BurnDownSelectionIntent().window == .session)
        #expect(BurnProviderSelectionIntent().provider == .claude)
    }

    @Test
    func `provider display catalog matches current descriptor titles`() throws {
        for choice in BurnProviderChoice.allCases {
            let display = try #require(BurnProviderChoice.caseDisplayRepresentations[choice])
            #expect(String(localized: display.title)
                == ProviderDescriptorRegistry.descriptor(for: choice.provider).metadata.displayName)
        }
    }

    @Test
    func `exhausted weekly quota still caps a session when its reset is unknown`() throws {
        let weekly = RateWindow(usedPercent: 100, windowMinutes: 10080, resetsAt: nil, resetDescription: nil)
        for provider in [UsageProvider.claude] {
            let state = try #require(BurnDownState(
                snapshot: Self.snapshot(provider: provider, primary: Self.window(minutes: 300), secondary: weekly),
                provider: provider,
                selection: .session))
            #expect(state.secondaryExhausted)
            #expect(state.selectedWindow?.remainingPercent == 0)
            #expect(state.blankPrimaryChart)
            #expect(state.selectedResetOverride == nil)
            #expect(state.window(for: .weekly) == nil)
        }
    }

    @Test
    func `unusual quota durations are never rounded down in labels`() {
        #expect(burnWindowLabel(90) == "90-minute limit")
        #expect(burnCompactWindowLabel(90, fallback: "") == "90M")
        #expect(burnWindowLabel(1500) == "25-hour limit")
        #expect(burnCompactWindowLabel(1500, fallback: "") == "25H")
    }

    private static func window(minutes: Int?, used: Double = 20) -> RateWindow {
        RateWindow(
            usedPercent: used,
            windowMinutes: minutes,
            resetsAt: Date(timeIntervalSince1970: 1_800_000_000),
            resetDescription: nil)
    }

    static func snapshot(
        provider: UsageProvider,
        primary: RateWindow?,
        secondary: RateWindow? = nil,
        tertiary: RateWindow? = nil,
        rows: [WidgetSnapshot.WidgetUsageRowSnapshot]? = nil) -> WidgetSnapshot
    {
        WidgetSnapshot(entries: [.init(
            provider: provider,
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000),
            primary: primary,
            secondary: secondary,
            tertiary: tertiary,
            usageRows: rows,
            creditsRemaining: nil,
            codeReviewRemainingPercent: nil,
            tokenUsage: nil,
            dailyUsage: [])], generatedAt: Date(timeIntervalSince1970: 1_800_000_000))
    }
}
