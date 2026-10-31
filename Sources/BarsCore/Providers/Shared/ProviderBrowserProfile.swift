import Foundation
#if os(macOS)
import SweetCookieKit
#endif

public struct ProviderBrowserProfile: Sendable, Equatable {
    public let browserID: String
    public let profileID: String

    public init(browserID: String, profileID: String) {
        self.browserID = browserID
        self.profileID = profileID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func selected(in config: ProviderConfig?, browsers: [String]) -> Self? {
        if config?.extensionValues["browserID"] != nil, config?.browserID == nil { return nil }
        guard let browserID = config?.browserID ?? browsers.first, browsers.contains(browserID) else { return nil }
        return Self(browserID: browserID, profileID: config?.browserProfileID ?? "")
    }

    #if os(macOS)
    #endif
}

extension ProviderConfig {
    public var browserID: String? {
        get { self.extensionValue(forKey: "browserID") }
        set { self.setExtensionValue(newValue, forKey: "browserID") }
    }

    public var browserProfileID: String? {
        get { self.extensionValue(forKey: "browserProfileID") }
        set { self.setExtensionValue(newValue, forKey: "browserProfileID") }
    }
}

extension ProviderSettingsSectionRegistration {}
