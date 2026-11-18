import Foundation
@testable import LiteratureCore

// DoclingDriver tests cover its process invocation contract.
enum DoclingDriverSuite {
    static func makeSandbox() throws -> (URL, URL, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lit-docling-\(UUID().uuidString)", isDirectory: true)
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
    static func installScript(_ bin: URL, body: String) throws -> URL {
        let script = bin.appendingPathComponent("docling")
        try body.write(to: script, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/chmod")
        p.arguments = ["+x", script.path]
        try p.run(); p.waitUntilExit()
        return script
    }

    @discardableResult
    static func runDriver(bin: URL, pdf: URL, out: URL) async throws -> URL {
        let driver = DoclingDriver(doclingPath: bin.appendingPathComponent("docling"),
                                   timeoutSeconds: 30)
        return try await driver.run(on: pdf, outputDir: out)
    }

    static var tests: [TestDesc] {
        var t: [TestDesc] = []
        t.append(TestDesc(suite: "DoclingDriver", name: "missingDoclingFailsClosed") {
            let (bin, pdf, out) = try makeSandbox()
            defer { Fixtures.cleanup(bin.appendingPathComponent("..")) }
            do {
                _ = try await runDriver(bin: bin, pdf: pdf, out: out)
                try failTest("缺 docling 应抛错")
            } catch let e as OcrDriverError {
                guard case .invalidPath = e else { try failTest("错型: \(e)") }
            }
        })
        t.append(TestDesc(suite: "DoclingDriver", name: "fakeDriverProducesPdf") {
            let (bin, pdf, out) = try makeSandbox()
            defer { Fixtures.cleanup(bin.appendingPathComponent("..")) }
            // docling 调用形态：$1=input.pdf $2=--output-dir $3=outdir
            try installScript(bin, body: "#!/bin/sh\ncp \"$1\" \"$3/book_ocr.pdf\"\nexit 0\n")
            let produced = try await runDriver(bin: bin, pdf: pdf, out: out)
            try expectTrue(produced.lastPathComponent == "book_ocr.pdf")
        })
        t.append(TestDesc(suite: "DoclingDriver", name: "emptyOutputFailsWithNoOutput") {
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
        return t
    }
}
