import Foundation
@testable import LiteratureCore

// MARK: - 测试（Share Extension 入站收录：ShareReceive 可测核心）
//
// 约束断言：Extension 不持凭据（类型零共享——本文件 grep 级断言 ShareReceive
// 不引用 WebDAV/SecretStore 符号）；拉取幂等（同名跳过/成功才消费源件）；
// 怪名不收；载荷 fail-closed。

enum ShareReceiveTests {
    /// 隔离临时目录（inbox + originals + captures.json 三件套）。
    static func makeEnv() throws -> (inbox: URL, originals: URL, captures: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lit-sharein-\(UUID().uuidString)", isDirectory: true)
        let inbox = root.appendingPathComponent(ShareReceive.inboxDirectoryName, isDirectory: true)
        let originals = root.appendingPathComponent("originals", isDirectory: true)
        let captures = root.appendingPathComponent("captures").appendingPathComponent("share-captures.json")
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        return (inbox, originals, captures)
    }

    static func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
    }

    static var tests: [TestDesc] {
        [
            TestDesc(suite: "ShareReceive", name: "fileNameWhitelistAcceptsOnlyGeneratedShape") {
                try expectTrue(ShareReceive.isAllowedFileName(
                    ShareReceive.makeFileName(kind: .pdf, now: Date(timeIntervalSince1970: 1_760_000_000.0),
                                              random: "abc123")))
                try expectTrue(ShareReceive.isAllowedFileName(
                    ShareReceive.makeFileName(kind: .text, now: Date(timeIntervalSince1970: 1_760_000_000.0),
                                              random: "xyz999")))
                // 用户输入形制/怪扩展/路径穿越全拒。
                try expectFalse(ShareReceive.isAllowedFileName("report.pdf"))
                try expectFalse(ShareReceive.isAllowedFileName("sharein-abc-123-def.pdf"))
                try expectFalse(ShareReceive.isAllowedFileName("sharein-abcdefgh-1760000000-abc123.TXT"))
                try expectFalse(ShareReceive.isAllowedFileName("../../etc/passwd"))
                try expectEqual(ShareReceive.kind(ofFileName: "sharein-abcdefgh-1760000000-abc123.pdf"),
                                ShareReceive.Kind.pdf)
                try expectNil(ShareReceive.kind(ofFileName: "sharein-abcdefgh-1760000000-abc123.doc"))
            },

            TestDesc(suite: "ShareReceive", name: "makeFileNameShapeMatchesWhitelistAlways") {
                // 程序生成名（默认随机段）必须稳定落在白名单内（100 例抽查）。
                for i in 0..<100 {
                    for kind in [ShareReceive.Kind.pdf, .text] {
                        let name = ShareReceive.makeFileName(
                            kind: kind, now: Date(timeIntervalSince1970: 1_760_000_000.0 + Double(i)))
                        try expectTrue(ShareReceive.isAllowedFileName(name), "生成名越白名单: \(name)")
                    }
                }
            },

            TestDesc(suite: "ShareReceive", name: "payloadValidationFailClosed") {
                // 空 / 超限 / 非 UTF-8 三拒（ShareInbox 同纪律）。
                try expectThrows(try ShareReceive.validatePayload(Data()), "空载荷必须拒")
                try expectThrows(try ShareReceive.validatePayload(Data([0xFF, 0xFE, 0xD8])),
                                 "非 UTF-8 必须拒")
                try expectThrows(
                    try ShareReceive.validatePayload(Data(repeating: 0x61, count: ShareReceive.maxPayloadBytes + 1)),
                    "超 64KiB 必须拒")
                // 合法载荷往返一致。
                let p = try ShareReceive.makeTextPayload(text: "https://example.org/a",
                                                         sourceLines: ["source: share-extension"])
                try expectTrue(String(decoding: p, as: UTF8.self)
                    .hasPrefix("# source: share-extension\nhttps://example.org/a"))
            },

            TestDesc(suite: "ShareReceive", name: "pullMergesPDFIntoOriginalsAndConsumesSource") {
                let env = try makeEnv()
                let name = ShareReceive.makeFileName(kind: .pdf, now: Date(timeIntervalSince1970: 1_760_000_000.0),
                                                     random: "pdf001")
                try write(Data("%PDF-1.4 tiny".utf8), to: env.inbox.appendingPathComponent(name))
                let outcome = ShareReceive.pull(inbox: env.inbox, originalsDirectory: env.originals,
                                                capturesFile: env.captures, now: Date(timeIntervalSince1970: 5))
                try expectEqual(outcome.mergedPDFs, [name])
                try expectEqual(outcome.mergedCaptures, [] as [String])
                // fileReception 语义：复制入书域待索引目录。
                try expectTrue(FileManager.default.fileExists(
                    atPath: env.originals.appendingPathComponent(name).path))
                // 成功才消费：源件已删。
                try expectFalse(FileManager.default.fileExists(
                    atPath: env.inbox.appendingPathComponent(name).path))
                try expectEqual(outcome.bytes, Int64(Data("%PDF-1.4 tiny".utf8).count))
            },

            TestDesc(suite: "ShareReceive", name: "pullMergesTextIntoCapturesJSON") {
                let env = try makeEnv()
                let name = ShareReceive.makeFileName(kind: .text, now: Date(timeIntervalSince1970: 1_760_000_000.0),
                                                     random: "url001")
                try write(try ShareReceive.makeTextPayload(text: "https://example.org/paper"),
                          to: env.inbox.appendingPathComponent(name))
                let outcome = ShareReceive.pull(inbox: env.inbox, originalsDirectory: env.originals,
                                                capturesFile: env.captures, now: Date(timeIntervalSince1970: 6))
                try expectEqual(outcome.mergedCaptures, [name])
                let records = ShareReceive.loadCaptures(at: env.captures)
                try expectEqual(records.count, 1)
                try expectEqual(records.first?.text, "https://example.org/paper")
                try expectEqual(records.first?.name, name)
                try expectEqual(records.first?.receivedAt, 6.0)
            },

            TestDesc(suite: "ShareReceive", name: "pullIsIdempotentOnSecondRun") {
                let env = try makeEnv()
                let pdf = ShareReceive.makeFileName(kind: .pdf, now: Date(timeIntervalSince1970: 1_760_000_000.0),
                                                    random: "pdf002")
                try write(Data("pdf".utf8), to: env.inbox.appendingPathComponent(pdf))
                let first = ShareReceive.pull(inbox: env.inbox, originalsDirectory: env.originals,
                                              capturesFile: env.captures)
                try expectEqual(first.mergedPDFs.count, 1)
                // inbox 已空 → 零新合并（源件消费制）。
                let second = ShareReceive.pull(inbox: env.inbox, originalsDirectory: env.originals,
                                               capturesFile: env.captures)
                try expectEqual(second.mergedPDFs, [] as [String])
                try expectEqual(second.mergedCaptures, [] as [String])
                // 目的地已有同名（源件未消费的镜像场景）→ 同名跳过（幂等约束）。
                try write(Data("pdf".utf8), to: env.inbox.appendingPathComponent(pdf))
                let dup = ShareReceive.pull(inbox: env.inbox, originalsDirectory: env.originals,
                                            capturesFile: env.captures)
                try expectEqual(dup.skippedExisting, [pdf])
                try expectEqual(dup.mergedPDFs, [] as [String])
                // 跳过不消费：源件保留（收件箱可见残留事实，不静默吞）。
                try expectTrue(FileManager.default.fileExists(
                    atPath: env.inbox.appendingPathComponent(pdf).path))
            },

            TestDesc(suite: "ShareReceive", name: "foreignNamesCountedNeverTouched") {
                let env = try makeEnv()
                let foreign = env.inbox.appendingPathComponent("someone-elses-file.txt")
                try write(Data("x".utf8), to: foreign)
                let pdf = ShareReceive.makeFileName(kind: .pdf, now: Date(timeIntervalSince1970: 1_760_000_000.0),
                                                    random: "pdf003")
                try write(Data("pdf".utf8), to: env.inbox.appendingPathComponent(pdf))
                let outcome = ShareReceive.pull(inbox: env.inbox, originalsDirectory: env.originals,
                                                capturesFile: env.captures)
                try expectEqual(outcome.foreignSkipped, 1)
                // 怪名永不删、永不收。
                try expectTrue(FileManager.default.fileExists(atPath: foreign.path))
                try expectEqual(outcome.mergedPDFs, [pdf])
            },

            TestDesc(suite: "ShareReceive", name: "oversizePDFFailsKeptNotMerged") {
                let env = try makeEnv()
                let pdf = ShareReceive.makeFileName(kind: .pdf, now: Date(timeIntervalSince1970: 1_760_000_000.0),
                                                    random: "pdf004")
                try write(Data(repeating: 0x50, count: ShareReceive.maxFileBytes + 1),
                          to: env.inbox.appendingPathComponent(pdf))
                let outcome = ShareReceive.pull(inbox: env.inbox, originalsDirectory: env.originals,
                                                capturesFile: env.captures)
                try expectEqual(outcome.failed, [pdf])
                try expectEqual(outcome.mergedPDFs, [] as [String])
                // 拒收不删源（人工可见，不静默吞件）。
                try expectTrue(FileManager.default.fileExists(
                    atPath: env.inbox.appendingPathComponent(pdf).path))
            },

            TestDesc(suite: "ShareReceive", name: "missingInboxIsQuietEmptyOutcome") {
                let env = try makeEnv()
                try FileManager.default.removeItem(at: env.inbox)
                let outcome = ShareReceive.pull(inbox: env.inbox, originalsDirectory: env.originals,
                                                capturesFile: env.captures)
                // Extension 从未写过件的常态：空收件箱＝零动作零报错。
                try expectEqual(outcome, ShareReceive.PullOutcome())
            },

            TestDesc(suite: "ShareReceive", name: "extensionStaysCredentialFreeTypeWise") {
                // 约束断言（grep 级，注释行不算——iOSCompileGate 先例）：
                // ShareReceive.swift 代码行不得引用凭据/传输面符号——
                // Extension target 只编本文件，凭据机制物理不可达。
                let repoRoot = URL(fileURLWithPath: #filePath)
                    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                let text = try String(contentsOf: repoRoot.appendingPathComponent(
                    "Sources/LiteratureCore/ShareReceive.swift"), encoding: .utf8)
                let code = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.hasPrefix("//") }
                    .joined(separator: "\n")
                for banned in ["WebDAV", "SecretStore", "credential", "Credential", "password", "URLSession"] {
                    try expectFalse(code.contains(banned), "ShareReceive 代码行不得出现 \(banned)（Extension 不持凭据）")
                }
            },

            TestDesc(suite: "ShareReceive", name: "appGroupIDMatchesExistingEntitlements") {
                // App Group 沿用既有 entitlements——
                // 断言 Core 常量与 iOS entitlements 文件同值。
                try expectEqual(ShareReceive.appGroupID, "group.com.example.literaturesearch.shared")
                let repoRoot = URL(fileURLWithPath: #filePath)
                    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                let ent = try String(contentsOf: repoRoot.appendingPathComponent(
                    "app/Support/LiteratureSearchiOS.entitlements"), encoding: .utf8)
                try expectTrue(ent.contains(ShareReceive.appGroupID),
                               "iOS entitlements 须含既有 App Group \(ShareReceive.appGroupID)")
            },
        ]
    }
}
