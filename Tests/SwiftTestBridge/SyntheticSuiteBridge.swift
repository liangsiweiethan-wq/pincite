import Testing
import LiteratureTestKit

// `swift test` entry mounts every registered synthetic
// case as one swift-testing parameterized case. `.serialized` keeps the exact
// sequential execution the executable runner provides, and the gate's exit
// code stays 0 iff every case passes. Case count = TestRegistry.caseCount.
// The environment filters (LIT_TESTS_ONLY / LIT_TEST_NAME) and real-library
// probes remain executable-runner-only; use `swift test --filter` here.

@Suite(.serialized)
struct SyntheticSuiteBridge {
    @Test("literaturesearch-tests synthetic suite", arguments: 0..<TestRegistry.caseCount)
    func syntheticCasePasses(_ index: Int) async throws {
        try await TestRegistry.runCase(index)
    }
}
