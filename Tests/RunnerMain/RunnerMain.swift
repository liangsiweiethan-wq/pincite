import LiteratureTestKit

// Test entry point (executable `literaturesearch-tests`): aggregates every
// registered synthetic suite and runs it for real; process exit code of
// 0 = all green. (Command Line Tools ship neither XCTest nor swift-testing;
// this executable runner is the equivalent. On a full Xcode toolchain the
// same cases run under `swift test` via Tests/SwiftTestBridge.)
// Suite registration moved to Tests/LiteratureCoreTests/AllSuites.swift
// Both entry points share one registry.

@main
struct LiteratureSearchTestMain {
    static func main() async {
        await SyntheticTestMain.run()
    }
}
