// swift-tools-version:5.9
// Literature Search — macOS literature PDF search tool.
// Targets:
//   LiteratureCore            — testable core (SQLite FTS5, PDF extraction, indexing, AI gating)
//   literaturesearch-cli      — safe CLI over the core (explicit commands only, no auto scan)
//   LiteratureSearchApp       — native SwiftUI/AppKit app (run with `swift run LiteratureSearchApp`)
//   LiteratureTestKit         — synthetic-only tests as a library (no real PDFs/books/credentials)
//   literaturesearch-tests    — executable runner over the kit (CLT-only fallback, exit code = result)
//   LiteratureCoreSwiftTests  — `swift test` bridge over the same kit (serialized swift-testing)
import PackageDescription

let package = Package(
    name: "LiteratureSearch",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "LiteratureCore",
            path: "Sources/LiteratureCore"
        ),
        // Pure UI routing/display strings (no SwiftUI). A library target so the
        // synthetic test executable can import it (executables cannot be
        // imported across targets under explicit module builds).
        .target(
            name: "LiteratureSearchUI",
            dependencies: ["LiteratureCore"],
            path: "Sources/LiteratureSearchUI"
        ),
        .executableTarget(
            name: "literaturesearch-cli",
            dependencies: ["LiteratureCore"],
            path: "Sources/literaturesearch-cli"
        ),
        .executableTarget(
            name: "LiteratureSearchApp",
            dependencies: ["LiteratureCore", "LiteratureSearchUI"],
            path: "Sources/LiteratureSearchApp"
        ),
        // Synthetic suites live in a plain library target so two entry points
        // share one registry (Tests/LiteratureCoreTests/AllSuites.swift).
        .target(
            name: "LiteratureTestKit",
            dependencies: ["LiteratureCore", "LiteratureSearchUI"],
            path: "Tests/LiteratureCoreTests"
        ),
        // CLT-only toolchain ships neither XCTest nor swift-testing, so the
        // synthetic test suite keeps a real executable runner (exit code = result).
        .executableTarget(
            name: "literaturesearch-tests",
            dependencies: ["LiteratureTestKit"],
            path: "Tests/RunnerMain"
        ),
        // `swift test` entry: one serialized swift-testing case per synthetic
        // TestDesc, so the gate's `swift test` runs the same 1000+ cases.
        .testTarget(
            name: "LiteratureCoreSwiftTests",
            dependencies: ["LiteratureTestKit"],
            path: "Tests/SwiftTestBridge"
        ),
    ]
)
