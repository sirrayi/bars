import Foundation
import Testing
@testable import Bars
@testable import BarsCore

@Suite(.serialized, ClaudeOAuthDefaultsFixtures(), ProviderTransportRegressionFixtures())
@MainActor
struct ProviderTransportGenerationTests {}
