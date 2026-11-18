import Foundation
@testable import LiteratureCore
@testable import LiteratureSearchUI

// MARK: - 一次性学习存储测试

enum SearchMemoryStoreSuite {
    static func makeStore() -> (SearchMemoryStore, URL) {
        let dir = Fixtures.makeTempDir("search-memory")
        return (SearchMemoryStore(fileURL: dir.appendingPathComponent("search-memory.json")), dir)
    }

    /// 全局 UserDefaults 键的 save/restore（套件串行下安全；泄漏即污染他套）。
    static func withLearningDisabled(_ body: () throws -> Void) rethrows {
        let key = SearchMemoryStore.habitLearningDefaultsKey
        let hadObject = UserDefaults.standard.object(forKey: key) != nil
        let previous = UserDefaults.standard.bool(forKey: key)
        UserDefaults.standard.set(false, forKey: key)
        defer {
            if hadObject { UserDefaults.standard.set(previous, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        try body()
    }

    static var tests: [TestDesc] {
        [
            TestDesc(suite: "SearchMemoryStore", name: "recordAnchorRoundTripUsesQueryNormalization") {
                let (store, root) = makeStore()
                defer { Fixtures.cleanup(root) }
                try expectNil(store.anchor(for: "law of nature"), "cold store has no anchor")
                store.recordSelection(query: "  Law  of  Nature ", bookID: "b1", page: 7,
                                      now: Date(timeIntervalSince1970: 100))
                let anchor = try expectNotNil(store.anchor(for: "law of nature"))
                try expectEqual(anchor.bookID, "b1")
                try expectEqual(anchor.page, 7)
                try expectNil(store.anchor(for: "different query"), "other queries unaffected")
            },

            TestDesc(suite: "SearchMemoryStore", name: "sameQueryOverwritesAnchor") {
                let (store, root) = makeStore()
                defer { Fixtures.cleanup(root) }
                store.recordSelection(query: "权利", bookID: "b1", page: 3,
                                      now: Date(timeIntervalSince1970: 1))
                store.recordSelection(query: "权利", bookID: "b2", page: 9,
                                      now: Date(timeIntervalSince1970: 2))
                try expectEqual(store.count, 1, "same normalized query keeps a single entry")
                let anchor = try expectNotNil(store.anchor(for: " 权利 "))
                try expectEqual(anchor.bookID, "b2")
                try expectEqual(anchor.page, 9)
            },

            TestDesc(suite: "SearchMemoryStore", name: "lruCapEvictsOldest") {
                let (store, root) = makeStore()
                defer { Fixtures.cleanup(root) }
                let first = "query-0000"
                store.recordSelection(query: first, bookID: "b0", page: 1)
                for i in 1..<SearchMemoryStore.maxEntries {
                    store.recordSelection(query: "query-\(String(format: "%04d", i))", bookID: "b\(i)", page: i)
                }
                try expectEqual(store.count, SearchMemoryStore.maxEntries)
                try expectNotNil(store.anchor(for: first), "oldest still present at capacity")
                store.recordSelection(query: "query-new-tail", bookID: "bx", page: 2)
                try expectEqual(store.count, SearchMemoryStore.maxEntries, "capacity holds")
                try expectNil(store.anchor(for: first), "oldest evicted beyond capacity")
                try expectNotNil(store.anchor(for: "query-new-tail"))
            },

            TestDesc(suite: "SearchMemoryStore", name: "corruptFileFailsOpenToEmpty") {
                let dir = Fixtures.makeTempDir("search-memory-corrupt")
                defer { Fixtures.cleanup(dir) }
                let url = dir.appendingPathComponent("search-memory.json")
                try Data("{not valid json!!".utf8).write(to: url)
                let store = SearchMemoryStore(fileURL: url)
                try expectEqual(store.count, 0)
                try expectNil(store.anchor(for: "anything"))
                store.recordSelection(query: "recovers", bookID: "b1", page: 4,
                                      now: Date(timeIntervalSince1970: 1_728_000_000))
                let original = try expectNotNil(store.anchor(for: "recovers"))
                let reloaded = SearchMemoryStore(fileURL: url)
                let reloadedAnchor = try expectNotNil(reloaded.anchor(for: "recovers"), "persists across reopen")
                try expectEqual(reloadedAnchor.bookID, original.bookID)
                try expectEqual(reloadedAnchor.page, original.page)
                // 日期编解码对称断言：load 侧漏配 .secondsSince1970 即在此回潮失败。
                try expectEqual(reloadedAnchor.at, original.at, "at survives reload (date codec symmetry)")
            },

            TestDesc(suite: "SearchMemoryStore", name: "guardsAndLearningToggle") {
                let (store, root) = makeStore()
                defer { Fixtures.cleanup(root) }
                store.recordSelection(query: "   ", bookID: "b1", page: 1)
                store.recordSelection(query: "ok", bookID: "b1", page: 0)
                store.recordSelection(query: "ok", bookID: "", page: 2)
                try expectEqual(store.count, 0, "empty query / invalid page / empty bookID ignored")
                try withLearningDisabled {
                    let off = SearchMemoryStore(fileURL: root.appendingPathComponent("off.json"))
                    off.recordSelection(query: "learning-off", bookID: "b1", page: 1)
                    try expectNil(off.anchor(for: "learning-off"), "toggle off: nothing recorded")
                    try expectEqual(off.count, 0)
                }
            },
        ]
    }
}
