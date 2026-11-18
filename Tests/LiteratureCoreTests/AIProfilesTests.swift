import Foundation
@testable import LiteratureSearchUI

// MARK: - AI 配置档案合成套件
//
// 覆盖：档案 CRUD+默认档案、按用途路由（未绑定回退默认/解绑回退）、
// resolveConfiguration 密钥解析、legacy 渠道导入幂等。Keychain 不进合成
// 测试（协议注入内存桩）。

enum AIProfilesSuite {
    final class MemoryKeyStorage: AIKeyStorage {
        public var storage: [String: String] = [:]
        public init() {}
        public func readKey(account: String) throws -> String? { storage[account] }
        public func writeKey(_ value: String, account: String) throws { storage[account] = value }
        public func deleteKey(account: String) throws { storage.removeValue(forKey: account) }
    }

    static var tests: [TestDesc] {
        [
            TestDesc(suite: "AIProfiles", name: "crudDefaultAndResolve") {
                let dir = Fixtures.makeTempDir("aiprof-crud")
                defer { Fixtures.cleanup(dir) }
                try await MainActor.run {
                    let keys = MemoryKeyStorage()
                    let store = AIProfilesStore(directory: dir, defaults: UserDefaults(suiteName: "aiprof-t1-\(UUID().uuidString)")!, keyStorage: keys)
                    let a = AIProfile(name: "渠道A", baseURL: "https://api.a.cn/v1", model: "model-a", note: "")
                    store.upsert(a)
                    try store.upsertKey("sk-a", for: a.id)
                    store.setDefault(id: a.id)
                    let b = AIProfile(name: "渠道B", baseURL: "https://api.b.cn/v1", model: "model-b", note: "")
                    store.upsert(b)
                    try store.upsertKey("sk-b", for: b.id)
                    // 默认档案解析：用途未绑定时取默认，密钥从桩读出。
                    guard case .success(let cfg) = store.resolveConfiguration(for: .summarize) else {
                        try failTest("默认档案应可解析")
                        return
                    }
                    try expectEqual(cfg.apiKey, "sk-a")
                    try expectEqual(cfg.model, "model-a")
                    // 绑定用途后按用途解析。
                    store.bind(.translate, to: b.id)
                    guard case .success(let tcfg) = store.resolveConfiguration(for: .translate) else {
                        try failTest("绑定档案应可解析")
                        return
                    }
                    try expectEqual(tcfg.apiKey, "sk-b")
                    // 解绑回退默认。
                    store.bind(.translate, to: nil)
                    guard case .success(let back) = store.resolveConfiguration(for: .translate) else {
                        try failTest("解绑后应回退默认")
                        return
                    }
                    try expectEqual(back.apiKey, "sk-a")
                    // 删除档案：路由清理+密钥删除；translate 回退默认 A。
                    store.deleteProfile(id: b.id)
                    try expectNil(try keys.readKey(account: b.id.uuidString), "删档同步删 Keychain 项")
                    try expectEqual(store.profile(for: .translate)?.id, a.id)
                }
            },
            TestDesc(suite: "AIProfiles", name: "emptyKeyRejectedAndUnknownRoutingDropped") {
                let dir = Fixtures.makeTempDir("aiprof-guard")
                defer { Fixtures.cleanup(dir) }
                let defaults = UserDefaults(suiteName: "aiprof-t2-\(UUID().uuidString)")!
                try await MainActor.run {
                    let keys = MemoryKeyStorage()
                    let store = AIProfilesStore(directory: dir, defaults: defaults, keyStorage: keys)
                    let a = AIProfile(name: "A", baseURL: "https://a", model: "ma", note: "")
                    store.upsert(a)
                    // 空密钥 fail-closed。
                    do {
                        try store.upsertKey("   ", for: a.id)
                        try failTest("空密钥应拒写")
                    } catch {}
                    try expectNil(try keys.readKey(account: a.id.uuidString))
                    // 路由表指向已删档案：重开时静默丢弃，回退默认。
                    try store.upsertKey("sk-a", for: a.id)   // 回退目标须有合法密钥
                    let b = AIProfile(name: "B", baseURL: "https://b", model: "mb", note: "")
                    store.upsert(b)
                    store.setDefault(id: a.id)
                    store.bind(.freeChat, to: b.id)
                    store.deleteProfile(id: b.id)
                    let reopened = AIProfilesStore(directory: dir, defaults: defaults, keyStorage: keys)
                    try expectEqual(reopened.profile(for: .freeChat)?.model, "ma",
                                    "悬空路由静默丢弃后回退默认档案")
                    if case .failure(let e) = reopened.resolveConfiguration(for: .freeChat) {
                        try failTest("路由丢弃后应回退默认，实际失败：\(e)")
                    }
                    let _ = 0
                }
            },
            TestDesc(suite: "AIProfiles", name: "legacyImportIdempotent") {
                let dir = Fixtures.makeTempDir("aiprof-legacy")
                defer { Fixtures.cleanup(dir) }
                try await MainActor.run {
                    let store = AIProfilesStore(directory: dir, defaults: UserDefaults(suiteName: "aiprof-t3-\(UUID().uuidString)")!, keyStorage: MemoryKeyStorage())
                    let legacy = dir.appendingPathComponent("ai_profile.json")
                    try """
                    {"channel":{"endpoint":"https://legacy.example/v1","model":"legacy-model","keychain_service":"svc","keychain_account":"acc"}}
                    """.write(to: legacy, atomically: true, encoding: .utf8)
                    let first = try store.importLegacyChannel(legacyJSON: legacy) { _, _ in "  sk-legacy-key  " }
                    try expectEqual(first.baseURL, "https://legacy.example/v1")
                    try expectEqual(first.model, "legacy-model")
                    // 幂等：二次导入返回既有档案不重复建。
                    let again = try store.importLegacyChannel(legacyJSON: legacy) { _, _ in "sk-other" }
                    try expectEqual(again.id, first.id)
                    try expectEqual(store.profiles.filter { $0.name == "现有渠道" }.count, 1)
                }
            },
        ]
    }
}
