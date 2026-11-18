import Foundation
@testable import LiteratureCore

// MARK: - mcp-serve stdio 壳层测试

enum MCPServeShellSuite {
    /// 64 位小写 hex 固定测试凭据（LocalAPIToken 形制；与逻辑层
    /// MCPBridgeSuite.fixedToken 不同值，两套断言互不串线可判别）。
    static let shellToken = String(repeating: "7", count: 64)
    /// 双源冲突断言用的另一把合法形制 token。
    static let otherToken = String(repeating: "9", count: 64)

    static var cliBin: URL {
        DesignGuardSuite.repoRoot.appendingPathComponent(".build/debug/literaturesearch-cli")
    }

    struct ServeResult {
        let status: Int32
        let out: String
        let err: String
    }

    // MARK: 组装助手

    /// 合成库（一本书两页，内容可检索；mcp-serve 启动只要求库文件存在）。
    @discardableResult
    static func makeSyntheticDB(_ label: String) throws -> URL {
        let dir = Fixtures.makeTempDir("mcp-serve-\(label)")
        let db = dir.appendingPathComponent("mcp.db")
        let store = try IndexStore(path: db)
        let book = IndexStore.BookRow(
            id: "bmcpspin0001", realPath: "/tmp/mcp-spin/bmcpspin0001.pdf",
            rootPath: "/tmp/mcp-spin", relPath: "bmcpspin0001.pdf",
            fileName: "bmcpspin0001.pdf",
            title: "MCP 壳层测试合成书", author: nil, version: nil, language: nil,
            metaSource: nil, firstFingerprint: "fp-mcp-spin", fingerprint: "fp-mcp-spin",
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
        return db
    }

    static func requestLine(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(data: data, encoding: .utf8)! + "\n"
    }

    /// initialize 握手行（合法行标杆：无需凭据、必有响应）。
    static func legalHandshake(id: String) -> String {
        requestLine(["jsonrpc": "2.0", "id": id, "method": "initialize",
                     "params": ["protocolVersion": "2025-06-18", "capabilities": [:],
                                "clientInfo": ["name": "mcp-shell-pin", "version": "0"]]])
    }

    static func toolsListLine(authorization: String?) -> String {
        var params: [String: Any] = [:]
        if let authorization { params["_meta"] = ["authorization": authorization] }
        return requestLine(["jsonrpc": "2.0", "id": "tl-1", "method": "tools/list",
                            "params": params])
    }

    /// 超限行体（70_000 字节 > MCPBridge.maxLineBytes = 65536；无换行）。
    static var oversizedBody: String { String(repeating: "x", count: 70_000) }

    /// 一次性拉起：规则文本落盘作 stdin（availableData 单 chunk 读到 EOF＝
    /// 服役到 EOF 自然退出），等退出后收 stdout/stderr。响应体量小（握手/
    /// 清单），不读不塞管道。
    static func runServe(db: URL, envToken: String?, argvToken: String?,
                         inputText: String) async throws -> ServeResult {
        let dir = db.deletingLastPathComponent()
        let inputFile = dir.appendingPathComponent("stdin-\(UUID().uuidString).txt")
        try Data(inputText.utf8).write(to: inputFile)
        defer { try? FileManager.default.removeItem(at: inputFile) }

        let p = Process()
        p.executableURL = cliBin
        var arguments = ["mcp-serve", "--db", db.path]
        if let argvToken { arguments += ["--token", argvToken] }
        p.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "LIT_MCP_TOKEN")
        if let envToken { env["LIT_MCP_TOKEN"] = envToken }
        p.environment = env
        let inHandle = try FileHandle(forReadingFrom: inputFile)
        p.standardInput = inHandle
        let outPipe = Pipe(); let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        try p.run()
        try await waitExit(p)
        let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(),
                         encoding: .utf8) ?? ""
        let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(),
                         encoding: .utf8) ?? ""
        return ServeResult(status: p.terminationStatus, out: out, err: err)
    }

    /// 有界等待退出；超时杀进程并抛断言红（防挂死拖垮整个 runner）。
    static func waitExit(_ p: Process, seconds: Double = 60) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while p.isRunning && Date() < deadline {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard !p.isRunning else {
            p.terminate()
            try failTest("mcp-serve \(Int(seconds))s 未退出（挂死）")
        }
    }

    /// oversized 日志行计数（stderr 里 "oversized line dropped" 出现次数）。
    static func droppedCount(in err: String) -> Int {
        err.components(separatedBy: "oversized line dropped").count - 1
    }

    static var tests: [TestDesc] {
        [
            TestDesc(suite: "MCPServeShell", name: "completeOversizedLineThenLegalLineStillServed") {
                try expectTrue(FileManager.default.fileExists(atPath: cliBin.path),
                               "CLI 二进制不存在——本测试要求先 swift build 再跑测试")
                let db = try makeSyntheticDB("pin1")
                defer { Fixtures.cleanup(db.deletingLastPathComponent()) }
                let input = oversizedBody + "\n" + legalHandshake(id: "legal-1")
                let r = try await runServe(db: db, envToken: shellToken, argvToken: nil,
                                           inputText: input)
                try expectEqual(r.status, 0, "应服役到 EOF 正常退出；stderr：\(r.err)")
                try expectTrue(r.out.contains("\"legal-1\""),
                               "合法行必须正常响应（修复前会被 discarding 误吞）；stdout：\(r.out.prefix(400))")
                try expectEqual(droppedCount(in: r.err), 1,
                                "超限行记一条 oversized 日志；stderr：\(r.err)")
            },

            TestDesc(suite: "MCPServeShell", name: "oversizedResidualAcrossPipeChunksThenLegalLineStillServed") {
                let db = try makeSyntheticDB("pin2")
                defer { Fixtures.cleanup(db.deletingLastPathComponent()) }
                let p = Process()
                p.executableURL = cliBin
                p.arguments = ["mcp-serve", "--db", db.path]
                var env = ProcessInfo.processInfo.environment
                env.removeValue(forKey: "LIT_MCP_TOKEN")
                env["LIT_MCP_TOKEN"] = shellToken
                p.environment = env
                let inPipe = Pipe(); let outPipe = Pipe(); let errPipe = Pipe()
                p.standardInput = inPipe; p.standardOutput = outPipe; p.standardError = errPipe
                try p.run()
                // chunk1：70_000 字节零换行——任一 append 后 buffer 必然 >64KiB
                // 且无换行可切，外层置位分支必然经过（清空＋置 discarding）。
                inPipe.fileHandleForWriting.write(Data(oversizedBody.utf8))
                try await Task.sleep(nanoseconds: 350_000_000)
                // chunk2：残包尾巴＋合法行。
                inPipe.fileHandleForWriting.write(Data(("tail-residue\n" + legalHandshake(id: "legal-2")).utf8))
                inPipe.fileHandleForWriting.closeFile() // EOF：显式停服
                try await waitExit(p)
                let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(),
                                 encoding: .utf8) ?? ""
                let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(),
                                 encoding: .utf8) ?? ""
                try expectEqual(p.terminationStatus, 0, "应正常退出；stderr：\(err)")
                try expectTrue(out.contains("\"legal-2\""),
                               "外层置位后合法行必须仍被服务；stdout：\(out.prefix(400))")
                try expectTrue(droppedCount(in: err) >= 1,
                               "残包尾巴应记 oversized 日志；stderr：\(err)")
            },

            TestDesc(suite: "MCPServeShell", name: "twoConsecutiveOversizedLinesThenLegalLineStillServed") {
                let db = try makeSyntheticDB("pin3")
                defer { Fixtures.cleanup(db.deletingLastPathComponent()) }
                let input = oversizedBody + "\n" + oversizedBody + "\n" + legalHandshake(id: "legal-3")
                let r = try await runServe(db: db, envToken: shellToken, argvToken: nil,
                                           inputText: input)
                try expectEqual(r.status, 0, "应服役到 EOF 正常退出；stderr：\(r.err)")
                try expectTrue(r.out.contains("\"legal-3\""),
                               "连续两超限行后合法行必须正常响应；stdout：\(r.out.prefix(400))")
                try expectEqual(droppedCount(in: r.err), 2, "两条超限行各记一条日志")
            },

            TestDesc(suite: "MCPServeShell", name: "envTokenServedAndAuthenticates") {
                let db = try makeSyntheticDB("pin4")
                defer { Fixtures.cleanup(db.deletingLastPathComponent()) }
                let r = try await runServe(db: db, envToken: shellToken, argvToken: nil,
                                           inputText: toolsListLine(authorization: shellToken))
                try expectEqual(r.status, 0, "env 供给应正常服役；stderr：\(r.err)")
                try expectTrue(r.out.contains("\"tools\""),
                               "tools/list 应带凭据通过路由器鉴权；stdout：\(r.out.prefix(400))")
                try expectFalse(r.out.contains("\"error\""),
                                "鉴权通过不得有 error；stdout：\(r.out.prefix(400))")
                try expectFalse(r.out.contains(shellToken),
                                "响应不得回显凭据")
            },

            TestDesc(suite: "MCPServeShell", name: "missingBothTokenSourcesFailsFastNamingEnv") {
                let db = try makeSyntheticDB("pin5")
                defer { Fixtures.cleanup(db.deletingLastPathComponent()) }
                let r = try await runServe(db: db, envToken: nil, argvToken: nil,
                                           inputText: legalHandshake(id: "n-1"))
                try expectNotEqual(r.status, 0, "永不无凭据服役：必须非零退出")
                try expectTrue(r.err.contains("LIT_MCP_TOKEN"),
                               "报错必须显式点名环境变量；stderr：\(r.err.prefix(400))")
            },

            TestDesc(suite: "MCPServeShell", name: "deprecatedArgvTokenFallsBackWithWarning") {
                let db = try makeSyntheticDB("pin6")
                defer { Fixtures.cleanup(db.deletingLastPathComponent()) }
                let r = try await runServe(db: db, envToken: nil, argvToken: shellToken,
                                           inputText: toolsListLine(authorization: shellToken))
                try expectEqual(r.status, 0, "deprecated 降级处理应可用；stderr：\(r.err)")
                try expectTrue(r.out.contains("\"tools\""),
                               "argv 降级处理 token 鉴权应通过；stdout：\(r.out.prefix(400))")
                try expectTrue(r.err.contains("deprecated"),
                               "必须写 deprecated 告警；stderr：\(r.err)")
            },

            TestDesc(suite: "MCPServeShell", name: "conflictingTokenSourcesFailClosed") {
                let db = try makeSyntheticDB("pin7")
                defer { Fixtures.cleanup(db.deletingLastPathComponent()) }
                let r = try await runServe(db: db, envToken: shellToken, argvToken: otherToken,
                                           inputText: legalHandshake(id: "n-2"))
                try expectNotEqual(r.status, 0, "双源冲突必须非零退出")
                try expectTrue(r.err.contains("conflict"),
                               "报错应点名冲突；stderr：\(r.err.prefix(400))")
            },

            TestDesc(suite: "MCPServeShell", name: "malformedEnvTokenRejectedByShapeGate") {
                let db = try makeSyntheticDB("pin8")
                defer { Fixtures.cleanup(db.deletingLastPathComponent()) }
                let r = try await runServe(db: db, envToken: String(repeating: "a", count: 63),
                                           argvToken: nil, inputText: legalHandshake(id: "n-3"))
                try expectNotEqual(r.status, 0, "形制门必须拒启")
                try expectTrue(r.err.contains("64 lowercase hex"),
                               "报错应点名形制；stderr：\(r.err.prefix(400))")
            },
        ]
    }
}
