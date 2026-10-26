import Foundation
import Testing
@testable import CodexBarCore

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

@Suite(.serialized)
struct BoundedChildProcessProofTests {}
