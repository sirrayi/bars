import Foundation
import Testing
@testable import BarsCore

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

@Suite(.serialized)
struct RPCChildProcessTeardownTests {
    @Test
    func `RPC stdin writes after child teardown fail without aborting`() throws {
        let stdin = RPCChildProcessInput()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/cat")
        process.standardInput = stdin.pipe
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()

        RPCChildProcessTeardown.terminate(process: process, stdin: stdin)

        #expect(throws: (any Error).self) {
            try stdin.write(Data("{\"id\":1}\n".utf8))
        }
        stdin.close()
    }

    @Test
    func `RPC stdin writes to an unexpectedly exited child throw without aborting`() throws {
        let stdin = RPCChildProcessInput()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/cat")
        process.standardInput = stdin.pipe
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()

        process.terminate()
        process.waitUntilExit()
        defer { stdin.close() }

        #expect(throws: (any Error).self) {
            try stdin.write(Data("{\"id\":1}\n".utf8))
        }
    }
}
