import Foundation
@testable import LiteratureCore

/// detect-body-start 参数解析回归断言。
///
/// 背景：`ArgCursor.value(for:)` 只把 position 推到"值"上并不跳过值；
/// 全文件 18 处解析循环统一依赖循环底的 `cursor.position += 1` 补偿步进。
/// `detectBodyStartCommand` 曾是唯一漏写补偿行的命令——带值旗标后的每个
/// token 落进 `default: throw`（线上症状：`unknown argument <db路径>`，
/// 两代二进制均复现）；打头出现纯布尔旗标（如 `--apply`）时 position 完全
/// 停滞，构成死循环。
///
/// CLI 可执行目标无法从本测试目标导入（Package.swift：executables cannot
/// be imported across targets），故双保险断言法：
/// 1. 源文本断言（DesignGuard 先例）：函数体内必须仍有循环底补偿行；
/// 2. 子进程行为断言：对合成库实跑 `.build/debug/literaturesearch-cli
///      detect-body-start`，要求 exit 0 且汇总行在（门禁先 swift build，
///      二进制必在；缺失即明确失败并提示，不静默跳过）。
enum DetectBodyStartArgParsingSuite {
    static var tests: [TestDesc] {
        [
            TestDesc(suite: "DetectBodyStartArgParsing", name: "loopKeepsCompensationAdvance") {
                let url = DesignGuardSuite.repoRoot.appendingPathComponent(
                    "Sources/literaturesearch-cli/LiteratureSearchCLI.swift")
                let text = try expectNotNil(try? String(contentsOf: url, encoding: .utf8))
                guard let start = text.range(of: "static func detectBodyStartCommand"),
                      let end = text.range(of: "\n    static func ",
                                           range: start.upperBound..<text.endIndex)
                else {
                    try failTest("detectBodyStartCommand 函数体定位失败（源结构漂移？）")
                }
                let body = String(text[start.lowerBound..<end.lowerBound])
                try expectTrue(
                    body.contains("cursor.position += 1"),
                    "detect-body-start 解析循环缺补偿步进行（参数解析回归）")
            },

            TestDesc(suite: "DetectBodyStartArgParsing", name: "cliAcceptsValuedFlagsEndToEnd") {
                let dir = Fixtures.makeTempDir("detect-body-start-args")
                let db = dir.appendingPathComponent("args-pin.db")
                let store = try IndexStore(path: db)
                let book = IndexStore.BookRow(
                    id: "bargspin001", realPath: "/tmp/args-pin/bargspin001.pdf",
                    rootPath: "/tmp/args-pin", relPath: "bargspin001.pdf",
                    fileName: "bargspin001.pdf",
                    title: "参数测试合成书", author: nil, version: nil, language: nil,
                    metaSource: nil, firstFingerprint: "fp-argspin", fingerprint: "fp-argspin",
                    fileSize: 1, mtime: 0, pageCount: 2, status: "ok", error: nil, indexedAt: 0)
                try store.upsertBook(book)
                var rows: [IndexStore.PageRow] = []
                for (i, text) in ["第一章 正文起始候选页", "第二章 续"].enumerated() {
                    let n = normalizeForSearch(text)
                    rows.append(IndexStore.PageRow(bookID: book.id, pageNumber: i + 1,
                                                   textOriginal: text, textNorm: n.text,
                                                   normStarts: n.starts, normEnds: n.ends))
                }
                try store.replacePages(bookID: book.id, rows)

                let bin = DesignGuardSuite.repoRoot
                    .appendingPathComponent(".build/debug/literaturesearch-cli")
                try expectTrue(FileManager.default.fileExists(atPath: bin.path),
                               "CLI 二进制不存在——本测试要求先 swift build 再跑测试")

                let p = Process()
                p.executableURL = bin
                p.arguments = ["detect-body-start", "--db", db.path, "--book", book.id]
                let pipe = Pipe()
                p.standardOutput = pipe
                p.standardError = pipe
                try p.run()
                p.waitUntilExit()
                let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                                 encoding: .utf8) ?? ""
                try expectEqual(p.terminationStatus, 0,
                                "detect-body-start 必须正常解析带值旗标；输出：\(out)")
                try expectTrue(out.contains("1 本书扫描"),
                               "扫描汇总行缺失；输出：\(out)")
                try expectFalse(out.contains("unknown argument"),
                                "带值旗标解析仍漂移；输出：\(out)")
            },
        ]
    }
}
