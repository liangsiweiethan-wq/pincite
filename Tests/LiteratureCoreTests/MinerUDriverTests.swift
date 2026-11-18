import Foundation
@testable import LiteratureCore

// MARK: - MinerUDriver 测试（假驱动脚本注入，不跑真模型）
//
// 五断言：invalid mineru 路径／invalid 输入路径／假驱动正常产出→返回产出路径／
// 假驱动零产出→noOutput／假驱动 exit 1→processFailed。
// 假驱动=临时目录内 shell 脚本（文件名冒充 mineru），内容按断言定制。
enum MinerUDriverSuite {
    static func makeSandbox() throws -> (URL, URL, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lit-mineru-\(UUID().uuidString)", isDirectory: true)
        let bin = dir.appendingPathComponent("bin", isDirectory: true)
        let input = dir.appendingPathComponent("in", isDirectory: true)
        let out = dir.appendingPathComponent("out", isDirectory: true)
        for d in [bin, input, out] {
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }
        let pdf = input.appendingPathComponent("book.pdf")
        FileManager.default.createFile(atPath: pdf.path, contents: Data("%PDF-1.4\n".utf8))
        return (bin, pdf, out)
    }

    @discardableResult
    static func installScript(_ bin: URL, name: String = "mineru", body: String) throws -> URL {
        let script = bin.appendingPathComponent(name)
        try body.write(to: script, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/chmod")
        p.arguments = ["+x", script.path]
        try p.run(); p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw TestFailure(message: "chmod 失败") }
        return script
    }

    @discardableResult
    static func runDriver(bin: URL, pdf: URL, out: URL, timeout: TimeInterval = 30) async throws -> URL {
        let driver = MinerUDriver(mineruPath: bin.appendingPathComponent("mineru"),
                                  timeoutSeconds: timeout)
        return try await driver.run(on: pdf, outputDir: out)
    }

    static var tests: [TestDesc] {
        var t: [TestDesc] = []
        t.append(TestDesc(suite: "MinerUDriver", name: "invalidMineruPathFailsClosed") {
            let (bin, pdf, out) = try makeSandbox()
            defer { Fixtures.cleanup(bin.appendingPathComponent("..")) }
            do {
                _ = try await runDriver(bin: bin, pdf: pdf, out: out)
                try failTest("缺 mineru 应抛错")
            } catch let e as OcrDriverError {
                guard case .invalidPath = e else { try failTest("错型: \(e)") }
            }
        })
        t.append(TestDesc(suite: "MinerUDriver", name: "missingInputFailsClosed") {
            let (bin, pdf, out) = try makeSandbox()
            defer { Fixtures.cleanup(bin.appendingPathComponent("..")) }
            try installScript(bin, body: "#!/bin/sh\nexit 0\n")
            try FileManager.default.removeItem(at: pdf)
            do {
                _ = try await runDriver(bin: bin, pdf: pdf, out: out)
                try failTest("缺输入应抛错")
            } catch let e as OcrDriverError {
                guard case .invalidPath = e else { try failTest("错型: \(e)") }
            }
        })
        t.append(TestDesc(suite: "MinerUDriver", name: "fakeDriverProducesOcrPdf") {
            let (bin, pdf, out) = try makeSandbox()
            defer { Fixtures.cleanup(bin.appendingPathComponent("..")) }
            try installScript(bin, body: "#!/bin/sh\n# $1=-p $2=input.pdf $3=-o $4=outdir\ncp \"$2\" \"$4/book_ocr.pdf\"\nexit 0\n")
            let produced = try await runDriver(bin: bin, pdf: pdf, out: out)
            try expectTrue(produced.lastPathComponent == "book_ocr.pdf", "产出名不符: \(produced.lastPathComponent)")
        })
        t.append(TestDesc(suite: "MinerUDriver", name: "emptyOutputFailsWithNoOutput") {
            let (bin, pdf, out) = try makeSandbox()
            defer { Fixtures.cleanup(bin.appendingPathComponent("..")) }
            try installScript(bin, body: "#!/bin/sh\nexit 0\n")
            do {
                _ = try await runDriver(bin: bin, pdf: pdf, out: out)
                try failTest("零产出应抛 noOutput")
            } catch let e as OcrDriverError {
                guard case .noOutput = e else { try failTest("错型: \(e)") }
            }
        })
        t.append(TestDesc(suite: "MinerUDriver", name: "driverExitOneFailsWithProcessFailed") {
            let (bin, pdf, out) = try makeSandbox()
            defer { Fixtures.cleanup(bin.appendingPathComponent("..")) }
            try installScript(bin, body: "#!/bin/sh\nexit 1\n")
            do {
                _ = try await runDriver(bin: bin, pdf: pdf, out: out)
                try failTest("exit 1 应抛 processFailed")
            } catch let e as OcrDriverError {
                guard case .processFailed(1) = e else { try failTest("错型: \(e)") }
            }
        })
        return t
    }
}
