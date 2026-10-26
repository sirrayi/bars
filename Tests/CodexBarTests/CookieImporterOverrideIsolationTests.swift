#if DEBUG && os(macOS)
import Foundation
import Testing
@testable import CodexBarCore

private actor CookieImporterOverrideBarrier {
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuations.append(continuation)
            guard self.continuations.count == 2 else { return }

            let continuations = self.continuations
            self.continuations.removeAll()
            continuations.forEach { $0.resume() }
        }
    }
}

struct CookieImporterOverrideIsolationTests {}
#endif
