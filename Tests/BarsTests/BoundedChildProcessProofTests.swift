import Foundation
import Testing
@testable import BarsCore

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

@Suite(.serialized)
struct BoundedChildProcessProofTests {}
