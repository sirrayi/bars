import Foundation

public struct AccountInfo: Equatable, Sendable {
    public let email: String?
    public let plan: String?

    public var hasIdentity: Bool {
        self.email?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ||
            self.plan?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    public init(email: String?, plan: String?) {
        self.email = email
        self.plan = plan
    }
}
