import CodexBarCore

extension UsageMenuCardView.Model {
    static func sessionEquivalentDetail(
        input: Input,
        weeklyWindow: RateWindow,
        weeklyWindowID: String?) -> UsagePaceText.SessionEquivalentDetail?
    {
        guard let forecast = input.sessionEquivalentForecast,
              forecast.applies(to: weeklyWindow, windowID: weeklyWindowID)
        else {
            return nil
        }
        return UsagePaceText.sessionEquivalentDetail(forecast: forecast)
    }
}
