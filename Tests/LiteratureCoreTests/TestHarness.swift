import Foundation

// MARK: - Minimal test harness (no XCTest under Command Line Tools)
//
// The suite runs for real: it builds actual synthetic PDFs, writes real SQLite
// databases and exercises PDFKit. Output: one line per test + a summary.
// Process exit code is 0 only when every test passes.

struct TestFailure: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
    init(message: String) { self.message = message }
}

struct TestDesc {
    let suite: String
    let name: String
    let body: () async throws -> Void
}

func failTest(_ message: String) throws -> Never {
    throw TestFailure(message: message)
}

func expectTrue(_ cond: Bool, _ message: String = "expected true") throws {
    guard cond else { try failTest(message) }
}

func expectFalse(_ cond: Bool, _ message: String = "expected false") throws {
    guard !cond else { try failTest(message) }
}

func expectEqual<T: Equatable>(_ a: T, _ b: T, _ message: String = "") throws {
    guard a == b else { try failTest("\(message) expected \(b), got \(a)") }
}

func expectNotEqual<T: Equatable>(_ a: T, _ b: T, _ message: String = "") throws {
    guard a != b else { try failTest("\(message) both values are \(a)") }
}

@discardableResult
func expectNotNil<T>(_ value: T?, _ message: String = "expected non-nil") throws -> T {
    guard let value else { try failTest(message) }
    return value
}

func expectNil<T>(_ value: T?, _ message: String = "expected nil") throws {
    guard value == nil else { try failTest("\(message), got \(value!)") }
}

/// Shared-host timing gates: set LIT_PERF_RELAXED=1 on CI to widen thresholds
/// and print a visible explanation instead of failing on a slow, shared runner.
var perfRelaxed: Bool {
    ProcessInfo.processInfo.environment["LIT_PERF_RELAXED"] == "1"
}

func perfLimit(_ normal: Double, relaxed: Double, _ label: String) -> Double {
    if perfRelaxed {
        FileHandle.standardError.write(Data("[perf] LIT_PERF_RELAXED=1: \(label) threshold \(normal) -> \(relaxed)\n".utf8))
        return relaxed
    }
    return normal
}

func expectThrows<T>(_ body: @autoclosure () throws -> T, _ message: String = "expected throw") throws {
    do {
        _ = try body()
    } catch {
        return
    }
    try failTest(message)
}

func expectThrowsAsync<T>(_ body: () async throws -> T, _ message: String = "expected throw") async throws {
    do {
        _ = try await body()
    } catch {
        return
    }
    try failTest(message)
}

@discardableResult
func expectNoThrow<T>(_ body: @autoclosure () throws -> T, _ message: String = "unexpected throw") throws -> T? {
    do {
        return try body()
    } catch {
        try failTest("\(message): \(error)")
    }
}

@discardableResult
func expectNoThrowAsync<T>(_ body: () async throws -> T, _ message: String = "unexpected throw") async throws -> T? {
    do {
        return try await body()
    } catch {
        try failTest("\(message): \(error)")
    }
}

enum TestRunner {
    static func main(_ suites: [[TestDesc]]) async {
        var passed = 0
        var failed = 0
        var failures: [(String, String)] = []
        let start = Date()
        for suite in suites {
            for test in suite {
                let label = "\(test.suite)/\(test.name)"
                do {
                    try await test.body()
                    passed += 1
                    print("PASS  \(label)")
                } catch {
                    failed += 1
                    failures.append((label, String(describing: error)))
                    print("FAIL  \(label): \(error)")
                }
            }
        }
        print("")
        print("====== literaturesearch-tests: \(passed) passed, \(failed) failed, \(passed + failed) total, \(String(format: "%.1f", Date().timeIntervalSince(start)))s ======")
        if !failures.isEmpty {
            print("failed tests:")
            for (label, reason) in failures {
                print("  - \(label): \(reason)")
            }
        }
        exit(failed == 0 ? 0 : 1)
    }
}
