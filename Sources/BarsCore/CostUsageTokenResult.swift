import Foundation

package struct CostUsageTokenResult: Sendable, Equatable {
    package let snapshot: CostUsageTokenSnapshot

    package init(snapshot: CostUsageTokenSnapshot) {
        self.snapshot = snapshot
    }
}
