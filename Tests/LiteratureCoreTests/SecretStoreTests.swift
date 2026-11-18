import Foundation
@testable import LiteratureCore
@testable import LiteratureSearchUI

// MARK: - SecretStore 协议契约套件（内存桩，零钥匙串副作用）
//
// 覆盖：save/read/delete 往返、覆盖写、幂等删、save 抛错可见、
// AIKeyStorage → SecretStore 桥接默认实现、生产类型满足协议（编译级）。

enum SecretStoreSuite {
    /// 协议契约内存桩（独立于 InMemoryKeyStorage：直接实现 SecretStore）。
    final class InMemorySecretStore: SecretStore {
        var storage: [String: String] = [:]
        var failSave = false

        func save(_ data: String, account: String) throws {
            if failSave { throw TestFailure(message: "stub save failed") }
            storage[account] = data
        }
        func read(account: String) -> String? { storage[account] }
        func delete(account: String) { storage.removeValue(forKey: account) }
    }

    static var tests: [TestDesc] {
        [
            TestDesc(suite: "SecretStore", name: "contractSaveReadDeleteRoundtrip") {
                let store = InMemorySecretStore()
                try expectNil(store.read(account: "a"), "空库读 nil")
                try store.save("sk-1", account: "a")
                try expectEqual(store.read(account: "a"), "sk-1")
                // 覆盖写：同 account 后写生效。
                try store.save("sk-2", account: "a")
                try expectEqual(store.read(account: "a"), "sk-2")
                try expectNil(store.read(account: "b"), "account 相互隔离")
                // 删除后读 nil；再删一次幂等（不抛、不崩）。
                store.delete(account: "a")
                try expectNil(store.read(account: "a"))
                store.delete(account: "a")
                store.delete(account: "never-existed")
            },
            TestDesc(suite: "SecretStore", name: "saveFailureMustSurface") {
                let store = InMemorySecretStore()
                store.failSave = true
                try expectThrows(try store.save("x", account: "a"),
                                 "写失败必须抛给调用方（不得静默吞）")
                try expectNil(store.read(account: "a"), "失败写不留半条")
            },
            TestDesc(suite: "SecretStore", name: "aiKeyStorageBridgesToSecretStore") {
                // AIKeyStorage 桩经协议扩展默认实现自动满足 SecretStore：
                // 同一实例两侧读写互通；SecretStore.delete 折叠错误为幂等。
                let keys = AIProfilesSuite.MemoryKeyStorage()
                let asSecret: SecretStore = keys
                try keys.writeKey("sk-bridge", account: "p1")
                try expectEqual(asSecret.read(account: "p1"), "sk-bridge")
                try asSecret.save("sk-via-secret", account: "p1")
                try expectEqual(try keys.readKey(account: "p1"), "sk-via-secret")
                asSecret.delete(account: "p1")
                try expectNil(try keys.readKey(account: "p1"), "桥接删除生效")
                asSecret.delete(account: "p1")   // 幂等
                // 读失败折叠为 nil（MemoryKeyStorage 不会抛；语义由实现保证）。
                try expectNil(asSecret.read(account: "ghost"))
            },
            TestDesc(suite: "SecretStore", name: "productionTypesSatisfyProtocol") {
                // 编译级契约：生产钥匙串实现与内存桩都满足 SecretStore。
                // 不对真实钥匙串做任何调用（零副作用）。
                let _: any SecretStore.Type = SecurityFrameworkKeyStorage.self
                let _: any SecretStore.Type = InMemoryKeyStorage.self
                let storage = SecurityFrameworkKeyStorage(service: SecurityFrameworkKeyStorage.webdavService)
                try expectEqual(storage.service, "com.example.literaturesearch.webdav",
                                "WebDAV 独立 service 可注入")
                try expectEqual(SecurityFrameworkKeyStorage().service,
                                SecurityFrameworkKeyStorage.service,
                                "默认 init 行为与历史一致")
            },
        ]
    }
}
