import Foundation
import Testing
@testable import CodexBarCore

enum CreditUsageTests {
    struct CreditCase: Sendable {
        let used: Double?
        let total: Double?
        let remaining: Double?
        let percent: Double?
    }
}
