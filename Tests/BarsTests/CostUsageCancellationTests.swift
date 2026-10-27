import Foundation
import Testing
@testable import BarsCore

struct CostUsageCancellationTests {
    @Test
    func `fetcher honors cancellation before token scan`() async throws {
        let gate = AsyncCancellationGate()
        let task = Task {
            await gate.wait()
            _ = try await CostUsageFetcher.loadTokenSnapshot(
                provider: .claude,
                scannerOptions: CostUsageScanner.Options())
        }
        await gate.waitUntilBlocked()
        task.cancel()
        await gate.open()

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
    }

    private func codexSessionContents(iso: String, tokenLineCount: Int) -> String {
        let session = #"{"type":"session_meta","payload":{"session_id":"session-1"}}"#
        let context = #"{"type":"turn_context","timestamp":"\#(iso)","payload":{"model":"gpt-5"}}"#
        return ([session, context] + Array(repeating: self.codexTokenLine(iso: iso), count: tokenLineCount))
            .joined(separator: "\n") + "\n"
    }

    private func codexTokenLine(iso: String) -> String {
        #"{"type":"event_msg","timestamp":"\#(iso)","payload":{"#
            + #""type":"token_count","info":{"last_token_usage":{"#
            + #""input_tokens":10,"cached_input_tokens":2,"output_tokens":4}}}}"#
    }
}

private actor AsyncCancellationGate {
    private var blockedContinuation: CheckedContinuation<Void, Never>?
    private var openContinuation: CheckedContinuation<Void, Never>?
    private var isBlocked = false
    private var isOpen = false

    func wait() async {
        self.isBlocked = true
        self.blockedContinuation?.resume()
        self.blockedContinuation = nil
        if self.isOpen {
            return
        }
        await withCheckedContinuation { continuation in
            self.openContinuation = continuation
        }
    }

    func waitUntilBlocked() async {
        if self.isBlocked {
            return
        }
        await withCheckedContinuation { continuation in
            self.blockedContinuation = continuation
        }
    }

    func open() {
        self.isOpen = true
        self.openContinuation?.resume()
        self.openContinuation = nil
    }
}
