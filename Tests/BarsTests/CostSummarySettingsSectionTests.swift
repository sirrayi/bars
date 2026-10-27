import Testing
@testable import Bars

@MainActor
struct CostSummarySettingsSectionTests {
    @Test
    func `cost settings explain reported and estimated sources`() {
        #expect(
            CostSummarySettingsSection.costDataExplanation()
                == "Costs may be provider-reported or estimated from token usage at public API prices. "
                + "Estimates are not subscription charges.")
    }
}
