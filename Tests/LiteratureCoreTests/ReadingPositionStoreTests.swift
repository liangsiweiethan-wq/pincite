import Foundation
@testable import LiteratureSearchUI

// MARK: - 阅读位置常驻持久合成套件（ReadingPositionStore）

enum ReadingPositionStoreSuite {
    static var tests: [TestDesc] {
        [
            TestDesc(suite: "ReadingPositionStore", name: "fileRoundTripWithTwoPage") {
                let dir = Fixtures.makeTempDir("rpos-roundtrip")
                defer { Fixtures.cleanup(dir) }
                try await MainActor.run {
                    let store = ReadingPositionStore(directory: dir)
                    store.save(page: 42, scale: 1.75, twoPage: true, for: "bookA")
                    store.save(page: 7, scale: 0.5, twoPage: false, for: "bookB")

                    // 重切实例（内存镜像清零）后必须全部从文件恢复。
                    let reopened = ReadingPositionStore(directory: dir)
                    let a = try expectNotNil(reopened.position(for: "bookA"))
                    try expectEqual(a.page, 42)
                    try expectEqual(a.scale, 1.75)
                    try expectTrue(a.twoPage, "bookA 双页偏好应持久为 true")
                    let b = try expectNotNil(reopened.position(for: "bookB"))
                    try expectEqual(b.page, 7)
                    try expectFalse(b.twoPage, "bookB 双页偏好应持久为 false")
                    // 键隔离：互不可见
                    try expectNotEqual(a.page, b.page)
                    try expectNil(reopened.position(for: "bookC"))
                }
            },
            TestDesc(suite: "ReadingPositionStore", name: "legacyJSONWithoutTwoPageDecodesAsSinglePage") {
                let dir = Fixtures.makeTempDir("rpos-legacy-decode")
                defer { Fixtures.cleanup(dir) }
                // 旧版存档：仅有 page/scale 两个字段。
                let legacy = #"{"bookA":{"page":13,"scale":2.0}}"#.data(using: .utf8)!
                let decoded = try expectNotNil(
                    try? JSONDecoder().decode([String: ReadingPosition].self, from: legacy))
                let pos = try expectNotNil(decoded["bookA"])
                try expectEqual(pos.page, 13)
                try expectEqual(pos.scale, 2.0)
                try expectFalse(pos.twoPage, "旧档缺 twoPage 字段应默认单页")
            },
            TestDesc(suite: "ReadingPositionStore", name: "invalidInputRejectedEntirely") {
                let dir = Fixtures.makeTempDir("rpos-invalid")
                defer { Fixtures.cleanup(dir) }
                try await MainActor.run {
                    let store = ReadingPositionStore(directory: dir)
                    // 先落一份合法档，再验证非法输入**整体拒写**（不覆盖、
                    // 不落半条字段）——整体拒写语义锁定。
                    store.save(page: 33, scale: 1.5, twoPage: true, for: "bookA")
                    store.save(page: 0, scale: 1.5, twoPage: false, for: "bookA")
                    store.save(page: 3, scale: 0, twoPage: false, for: "bookA")
                    store.save(page: -1, scale: -2, twoPage: false, for: "bookA")
                    let reopened = ReadingPositionStore(directory: dir)
                    let kept = try expectNotNil(reopened.position(for: "bookA"))
                    try expectEqual(kept.page, 33, "非法写入不得触碰已有合法档")
                    try expectEqual(kept.scale, 1.5)
                    try expectTrue(kept.twoPage, "整体拒写：连 twoPage 也不得被非法写入重置")
                    // 从未写过档的 book：仍然无档（不落半条）。
                    try expectNil(reopened.position(for: "bookB"), "page=0 对无档书也不落半条档")
                    store.save(page: 0, scale: 1.5, for: "bookB")
                    let reopened2 = ReadingPositionStore(directory: dir)
                    try expectNil(reopened2.position(for: "bookB"))
                }
            },
            TestDesc(suite: "ReadingPositionStore", name: "twoPageNilKeepsExistingPreference") {
                let dir = Fixtures.makeTempDir("rpos-nil-keep")
                defer { Fixtures.cleanup(dir) }
                try await MainActor.run {
                    let store = ReadingPositionStore(directory: dir)
                    store.save(page: 10, scale: 2.0, twoPage: true, for: "bookA")
                    // 只更新页/缩放、不动双页（persistPosition 翻页降级处理路径）：
                    // twoPage 传 nil 必须保留旧偏好，而不是坍缩回 false。
                    store.save(page: 11, scale: 2.0, for: "bookA")
                    let pos = try expectNotNil(store.position(for: "bookA"))
                    try expectEqual(pos.page, 11)
                    try expectTrue(pos.twoPage, "twoPage=nil 应保留既有双页偏好")
                    // 无既有档时 nil 降级处理单页（新书写档不继承他书偏好）。
                    store.save(page: 1, scale: 1.0, for: "bookB")
                    try expectFalse(try expectNotNil(store.position(for: "bookB")).twoPage)
                }
            },
            TestDesc(suite: "ReadingPositionStore", name: "corruptFileFailsClosedToEmpty") {
                let dir = Fixtures.makeTempDir("rpos-corrupt")
                defer { Fixtures.cleanup(dir) }
                try "not json at all".write(
                    to: dir.appendingPathComponent("reader-preferences.json"),
                    atomically: true, encoding: .utf8)
                try await MainActor.run {
                    let store = ReadingPositionStore(directory: dir)
                    try expectNil(store.position(for: "anyBook"), "坏档应 fail-closed 视为无存档")
                    // 后续合法写入仍可正常落盘（不被坏档卡死）。
                    store.save(page: 5, scale: 1.2, twoPage: true, for: "bookA")
                    let reopened = ReadingPositionStore(directory: dir)
                    try expectEqual(reopened.position(for: "bookA")?.page, 5)
                }
            },
            TestDesc(suite: "ReadingPositionStore", name: "legacyUserDefaultsFallbackMigratesAndKeepsLegacy") {
                let dir = Fixtures.makeTempDir("rpos-legacy-fallback")
                defer { Fixtures.cleanup(dir) }
                let suiteName = "litsearch-rpos-test-\(UUID().uuidString)"
                let seedDefaults = UserDefaults(suiteName: suiteName)!
                defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
                let legacyDict = #"{"oldBook":{"page":9,"scale":1.1}}"#.data(using: .utf8)!
                seedDefaults.set(legacyDict, forKey: "readingPositions")

                try await MainActor.run {
                    let legacyDefaults = UserDefaults(suiteName: suiteName)!
                    let store = ReadingPositionStore(directory: dir, legacyDefaults: legacyDefaults)
                    let pos = try expectNotNil(store.position(for: "oldBook"), "legacy UserDefaults 档应可读")
                    try expectEqual(pos.page, 9)

                    // 回退命中后一次性迁移写穿文件：文件独立可读，不再依赖旧档。
                    let fileData = try Data(contentsOf: dir.appendingPathComponent("reader-preferences.json"))
                    let fromFile = try expectNotNil(
                        try? JSONDecoder().decode([String: ReadingPosition].self, from: fileData))
                    try expectEqual(fromFile["oldBook"]?.page, 9)
                    // 旧档只读不删。
                    try expectNotNil(legacyDefaults.data(forKey: "readingPositions"),
                                     "迁移写穿后旧 UserDefaults 档必须原样保留")
                    // 迁移后新写入走文件，旧档继续不动。
                    store.save(page: 12, scale: 1.2, for: "oldBook")
                    try expectNotNil(legacyDefaults.data(forKey: "readingPositions"))
                    try expectEqual(try expectNotNil(
                        ReadingPositionStore(directory: dir).position(for: "oldBook")).page, 12)
                }
            },
            TestDesc(suite: "ReadingPositionStore", name: "saveMergesWithoutTouchingOtherBooks") {
                let dir = Fixtures.makeTempDir("rpos-merge")
                defer { Fixtures.cleanup(dir) }
                try await MainActor.run {
                    let store = ReadingPositionStore(directory: dir)
                    store.save(page: 10, scale: 2.0, twoPage: false, for: "bookA")
                    store.save(page: 20, scale: 3.0, twoPage: true, for: "bookB")
                    // 仅改 bookA 的双页偏好（详情栏 toggle 的合并写语义）。
                    let existing = try expectNotNil(store.position(for: "bookA"))
                    store.save(page: existing.page, scale: existing.scale, twoPage: true, for: "bookA")

                    let reopened = ReadingPositionStore(directory: dir)
                    try expectTrue(try expectNotNil(reopened.position(for: "bookA")).twoPage)
                    try expectEqual(try expectNotNil(reopened.position(for: "bookA")).page, 10)
                    try expectEqual(try expectNotNil(reopened.position(for: "bookB")).page, 20)
                    try expectTrue(try expectNotNil(reopened.position(for: "bookB")).twoPage)
                }
            },
            // 锁定高亮锚点：同款 JSON 新字段 anchorPage，向后兼容。
            TestDesc(suite: "ReadingPositionStore", name: "anchorPageRoundTripPreservesSiblings") {
                let dir = Fixtures.makeTempDir("rpos-anchor")
                defer { Fixtures.cleanup(dir) }
                try await MainActor.run {
                    let store = ReadingPositionStore(directory: dir)
                    store.save(page: 42, scale: 1.75, twoPage: true, for: "bookA")
                    // 只改锚点：页/缩放/双页偏好原样保留。
                    store.save(anchorPage: 30, for: "bookA")
                    let reopened = ReadingPositionStore(directory: dir)
                    let pos = try expectNotNil(reopened.position(for: "bookA"))
                    try expectEqual(pos.anchorPage ?? 0, 30)
                    try expectEqual(pos.page, 42, "锚点写入不得触碰页码")
                    try expectEqual(pos.scale, 1.75)
                    try expectTrue(pos.twoPage, "锚点写入不得触碰双页偏好")
                    // 锚点清除（传 nil）与其余字段互不影响。
                    store.save(anchorPage: nil, for: "bookA")
                    let cleared = try expectNotNil(ReadingPositionStore(directory: dir).position(for: "bookA"))
                    try expectNil(cleared.anchorPage, "传 nil 应清除锚点")
                    try expectEqual(cleared.page, 42)
                    // 键隔离：他书锚点写入不影响 bookA（bookA 锚点已在上方
                    // 清除，bookB 写入不得使其复活）。
                    store.save(anchorPage: 7, for: "bookB")
                    try expectEqual(try expectNotNil(
                        ReadingPositionStore(directory: dir).position(for: "bookA")).anchorPage ?? 0, 0,
                        "bookB 写锚点不得触碰 bookA 已清除的锚点")
                    let b = try expectNotNil(ReadingPositionStore(directory: dir).position(for: "bookB"))
                    try expectEqual(b.anchorPage ?? 0, 7)
                    try expectEqual(b.page, 1, "无既有档时锚点写入以占位档建仓")
                    // 非法锚点页 fail-closed 忽略。
                    store.save(anchorPage: -3, for: "bookA")
                    try expectNil(ReadingPositionStore(directory: dir).position(for: "bookA")?.anchorPage,
                                  "非法锚点页（<1）不得落盘")
                }
            },
            TestDesc(suite: "ReadingPositionStore", name: "legacyJSONWithoutAnchorPageDecodesAsNil") {
                // 旧档无 anchorPage 字段：解码为 nil（向后兼容），twoPage 语义不变。
                let legacy = #"{"bookA":{"page":13,"scale":2.0,"twoPage":true}}"#.data(using: .utf8)!
                let decoded = try expectNotNil(
                    try? JSONDecoder().decode([String: ReadingPosition].self, from: legacy))
                let pos = try expectNotNil(decoded["bookA"])
                try expectNil(pos.anchorPage, "旧档缺 anchorPage 字段应解码为 nil")
                try expectTrue(pos.twoPage)
                try expectEqual(pos.page, 13)
            },
        ]
    }
}
