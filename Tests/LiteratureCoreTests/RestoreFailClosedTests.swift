import CryptoKit
import Foundation
import SQLite3
@testable import LiteratureCore

// MARK: - 修复失败路径测试五枚（修复自产）

enum RestoreFailClosedSuite {

    // MARK: 助手（句柄全部限域，出域即 deinit 关连接）

    /// 建带 marker 表 t(v) 的最小 SQLite 库，写初始值。
    private static func makeMarkerDB(at url: URL, value: String) throws {
        let db = try SQLiteDatabase(path: url.path)
        try db.exec("CREATE TABLE t(v TEXT);")
        try db.exec("INSERT INTO t(v) VALUES ('\(value)');")
    }

    /// 改写 marker 值（新开连接，写完即关）。
    private static func writeMarker(at url: URL, _ value: String) throws {
        let db = try SQLiteDatabase(path: url.path)
        try db.exec("UPDATE t SET v='\(value)';")
    }

    /// 新开连接读 marker 值（避免持旧句柄读旧 inode）。
    private static func readMarker(at url: URL) throws -> String {
        let db = try SQLiteDatabase(path: url.path)
        let st = try db.prepare("SELECT v FROM t;")
        try expectTrue(try st.step(), "marker 行必须存在")
        return st.text(0)
    }

    private static func makeTwoBookFixture() throws
        -> (dirA: URL, dirB: URL, snapDir: URL, urlA: URL, urlB: URL, snap: URL, mgr: SnapshotManager) {
        let dirA = Fixtures.makeTempDir("batchd-fc-a")
        let dirB = Fixtures.makeTempDir("batchd-fc-b")
        let snapDir = Fixtures.makeTempDir("batchd-fc-snap")
        let urlA = dirA.appendingPathComponent("alpha.db")
        let urlB = dirB.appendingPathComponent("beta.db")
        try makeMarkerDB(at: urlA, value: "v1")
        try makeMarkerDB(at: urlB, value: "v1")
        let mgr = SnapshotManager(snapshotDir: snapDir,
                                  sources: [("alpha", urlA), ("beta", urlB)])
        let snap = try mgr.takeSnapshot()
        try writeMarker(at: urlA, "v2")
        try writeMarker(at: urlB, "v2")
        return (dirA, dirB, snapDir, urlA, urlB, snap, mgr)
    }

    /// 复位 Keychain 注入点到生产默认值（密闭化：私有实现不直触）。
    private static func resetKeychainHooks() {
        AnnotationCrypto.keychainLoadKey = AnnotationCrypto.productionKeychainLoad
        AnnotationCrypto.keychainStoreKey = AnnotationCrypto.productionKeychainStore
    }

    static var tests: [TestDesc] {
        [
            TestDesc(suite: "RestoreFailClosed", name: "backupStepBusyThrowsAndCleansPartialDst") {
                let snapDir = Fixtures.makeTempDir("batchd-fc-busy")
                defer { Fixtures.cleanup(snapDir) }
                let srcDir = Fixtures.makeTempDir("batchd-fc-busy-src")
                defer { Fixtures.cleanup(srcDir) }
                let srcURL = srcDir.appendingPathComponent("alpha.db")
                try makeMarkerDB(at: srcURL, value: "v1")
                SnapshotManager.backupStepOverride = { _, _ in SQLITE_BUSY }
                defer { SnapshotManager.backupStepOverride = nil }
                let mgr = SnapshotManager(snapshotDir: snapDir, sources: [("alpha", srcURL)])
                do {
                    _ = try mgr.takeSnapshot()
                    try failTest("step BUSY 必须抛错，不得静默出半成品快照")
                } catch let e as NSError {
                    try expectEqual(e.domain, "SnapshotError", "域应为 SnapshotError")
                    try expectEqual(e.code, 2, "应为 step 失败 code2")
                }
                // 半成品清理：任何时间戳子目录内都不得残留 alpha.db。
                let subs = try FileManager.default.contentsOfDirectory(at: snapDir, includingPropertiesForKeys: nil)
                for sub in subs where sub.hasDirectoryPath {
                    let leftovers = try FileManager.default.contentsOfDirectory(at: sub, includingPropertiesForKeys: nil)
                    try expectFalse(leftovers.contains { $0.lastPathComponent == "alpha.db" },
                                    "step 失败后不得残留半成品库文件")
                }
            },

            TestDesc(suite: "RestoreFailClosed", name: "restoreRollsBackWhenSecondReplaceFails") {
                let fx = try makeTwoBookFixture()
                defer { Fixtures.cleanup(fx.dirA); Fixtures.cleanup(fx.dirB); Fixtures.cleanup(fx.snapDir) }
                var calls = 0
                SnapshotManager.replaceItemHook = { target, tmp in
                    calls += 1
                    if calls == 1 {
                        _ = try FileManager.default.replaceItemAt(target, withItemAt: tmp)
                    } else {
                        throw TestFailure(message: "注入：第二库替换失败")
                    }
                }
                defer { SnapshotManager.replaceItemHook = nil }
                do {
                    try fx.mgr.restore(snapshot: fx.snap, to: [("alpha", fx.urlA), ("beta", fx.urlB)])
                    try failTest("第二库替换失败必须抛错")
                } catch let e as TestFailure {
                    try expectTrue(e.message.contains("第二库"), "应是我们注入的失败，实际：\(e.message)")
                } catch {
                    try failTest("意外错误类型：\(error)")
                }
                try expectEqual(try readMarker(at: fx.urlA), "v2", "第一库必须从安全网回滚回 restore 前态")
                try expectEqual(try readMarker(at: fx.urlB), "v2", "第二库必须零接触")
                for d in [fx.dirA, fx.dirB] {
                    let files = try FileManager.default.contentsOfDirectory(at: d, includingPropertiesForKeys: nil)
                    try expectFalse(files.contains { $0.lastPathComponent.hasSuffix(".restore-staging") },
                                    "失败路径不得残留暂存件")
                }
            },

            TestDesc(suite: "RestoreFailClosed", name: "restoreThrowsWhenSnapshotSourceMissing") {
                let fx = try makeTwoBookFixture()
                defer { Fixtures.cleanup(fx.dirA); Fixtures.cleanup(fx.dirB); Fixtures.cleanup(fx.snapDir) }
                try FileManager.default.removeItem(at: fx.snap.appendingPathComponent("beta.db"))
                do {
                    try fx.mgr.restore(snapshot: fx.snap, to: [("alpha", fx.urlA), ("beta", fx.urlB)])
                    try failTest("快照源缺失必须显式抛错")
                } catch let e as NSError {
                    try expectEqual(e.domain, "SnapshotError", "域应为 SnapshotError")
                    try expectEqual(e.code, 3, "应为源缺失 code3")
                }
                try expectEqual(try readMarker(at: fx.urlA), "v2", "前置校验失败目标一必须零接触")
                try expectEqual(try readMarker(at: fx.urlB), "v2", "前置校验失败目标二必须零接触")
                let subs = try FileManager.default.contentsOfDirectory(at: fx.snapDir, includingPropertiesForKeys: nil)
                try expectFalse(subs.contains { $0.lastPathComponent.hasPrefix("pre-restore") },
                                "前置校验先于安全网：失败时不得已建 pre-restore 目录")
            },

            TestDesc(suite: "RestoreFailClosed", name: "ensureKeyDuplicateReturnsExistingKey") {
                let preset = SymmetricKey(size: .bits256)
                let presetData = preset.withUnsafeBytes { Data($0) }
                var loadCount = 0
                AnnotationCrypto.keychainLoadKey = {
                    loadCount += 1
                    // 初查=项不存在；store 撞 duplicate 后重读=命中预置项。
                    return loadCount == 1 ? nil : SymmetricKey(data: presetData)
                }
                AnnotationCrypto.keychainStoreKey = { _ in errSecDuplicateItem }
                defer { resetKeychainHooks() }
                let got = try AnnotationCrypto.ensureKey()
                try expectEqual(got.withUnsafeBytes { Data($0) }, presetData,
                                "duplicate 时必须返回 Keychain 既有钥，不得返回临时钥")
                try expectEqual(loadCount, 2, "loadKey 应恰被调两次（初查+重读）")
            },

            TestDesc(suite: "RestoreFailClosed", name: "ensureKeyDuplicateRereadFailureThrows") {
                AnnotationCrypto.keychainLoadKey = { nil }
                AnnotationCrypto.keychainStoreKey = { _ in errSecDuplicateItem }
                defer { resetKeychainHooks() }
                do {
                    _ = try AnnotationCrypto.ensureKey()
                    try failTest("重读失败必须抛错，不得返回临时钥")
                } catch let e as AnnotationCrypto.CryptoError {
                    if case .keychainRead = e {} else {
                        try failTest("应抛 keychainRead，实际：\(e)")
                    }
                } catch {
                    try failTest("应抛 CryptoError.keychainRead，实际：\(error)")
                }
            },

            // MARK: - 测试

            TestDesc(suite: "RestoreFailClosed", name: "restoreRollbackFailureThrowsCompoundError") {
                let fx = try makeTwoBookFixture()
                defer { Fixtures.cleanup(fx.dirA); Fixtures.cleanup(fx.dirB); Fixtures.cleanup(fx.snapDir) }
                var calls = 0
                SnapshotManager.replaceItemHook = { target, tmp in
                    calls += 1
                    if calls == 1 {
                        _ = try FileManager.default.replaceItemAt(target, withItemAt: tmp)
                    } else {
                        // 注入：第二库替换失败前毁掉安全网（模拟安全网复制/恢复失败）
                        let subs = try FileManager.default.contentsOfDirectory(
                            at: fx.snapDir, includingPropertiesForKeys: nil)
                        for sub in subs where sub.lastPathComponent.hasPrefix("pre-restore") {
                            try FileManager.default.removeItem(at: sub)
                        }
                        throw TestFailure(message: "注入：第二库替换失败")
                    }
                }
                defer { SnapshotManager.replaceItemHook = nil }
                do {
                    try fx.mgr.restore(snapshot: fx.snap, to: [("alpha", fx.urlA), ("beta", fx.urlB)])
                    try failTest("安全网被毁的回滚必须抛复合错误，不得静默返回")
                } catch let e as NSError {
                    try expectEqual(e.domain, "SnapshotError", "域应为 SnapshotError")
                    try expectEqual(e.code, 4, "应为「恢复失败且回滚失败」复合错误 code4")
                    let msg = e.localizedDescription
                    try expectTrue(msg.contains("ROLLBACK FAILED"), "复合错误须含回滚失败段，实际：\(msg)")
                    try expectTrue(msg.contains("第二库"), "复合错误须保留原始错误，实际：\(msg)")
                    try expectTrue(msg.contains("safety snapshot missing"), "须点名安全网缺失这一回滚失败，实际：\(msg)")
                } catch {
                    try failTest("意外错误类型：\(error)")
                }
                try expectTrue(FileManager.default.fileExists(atPath: fx.urlA.path),
                               "回滚失败时目标库不得被删成缺失（先拷后删基准）")
            },

            TestDesc(suite: "RestoreFailClosed", name: "restoreRestoresTargetSidecarsOnRollback") {
                let fx = try makeTwoBookFixture()
                defer { Fixtures.cleanup(fx.dirA); Fixtures.cleanup(fx.dirB); Fixtures.cleanup(fx.snapDir) }
                let walA = URL(fileURLWithPath: fx.urlA.path + "-wal")
                let shmA = URL(fileURLWithPath: fx.urlA.path + "-shm")
                try Data("WAL-MARKER-A".utf8).write(to: walA)
                try Data("SHM-MARKER-A".utf8).write(to: shmA)
                var walSizeAtSave = -1
                var shmSizeAtSave = -1
                var calls = 0
                SnapshotManager.replaceItemHook = { target, tmp in
                    calls += 1
                    if calls == 1 {
                        _ = try FileManager.default.replaceItemAt(target, withItemAt: tmp)
                        // 此刻 = sidecar 刚保存完（urlA 位已 move 空）：
                        // 从安全网目录读保存件尺寸＝删前基线
                        let subs = try FileManager.default.contentsOfDirectory(
                            at: fx.snapDir, includingPropertiesForKeys: nil)
                        if let safety = subs.first(where: { $0.lastPathComponent.hasPrefix("pre-restore") }) {
                            walSizeAtSave = (try? Data(contentsOf: safety.appendingPathComponent("alpha.db-wal")))?.count ?? -1
                            shmSizeAtSave = (try? Data(contentsOf: safety.appendingPathComponent("alpha.db-shm")))?.count ?? -1
                        }
                    } else {
                        throw TestFailure(message: "注入：第二库替换失败")
                    }
                }
                defer { SnapshotManager.replaceItemHook = nil }
                do {
                    try fx.mgr.restore(snapshot: fx.snap, to: [("alpha", fx.urlA), ("beta", fx.urlB)])
                    try failTest("第二库替换失败必须抛错")
                } catch let e as TestFailure {
                    try expectTrue(e.message.contains("第二库"), "应是我们注入的失败，实际：\(e.message)")
                } catch {
                    try failTest("意外错误类型：\(error)")
                }
                try expectTrue(walSizeAtSave > 0 && shmSizeAtSave > 0,
                               "删前基线必须已捕获（wal=\(walSizeAtSave) shm=\(shmSizeAtSave)）")
                try expectEqual(String(decoding: try Data(contentsOf: walA), as: UTF8.self),
                                "WAL-MARKER-A", "第一库 -wal 必须从安全网完整还原（删前保存基准）")
                let shmNow = (try? Data(contentsOf: shmA))?.count ?? -1
                try expectTrue(shmNow == shmSizeAtSave,
                               "第一库 -shm 必须以删前原样回位（基线\(shmSizeAtSave)B，实际\(shmNow)B）")
            },

            TestDesc(suite: "RestoreFailClosed", name: "restoreStagingFailureCleansAllRegisteredTmps") {
                let fx = try makeTwoBookFixture()
                defer {
                    // 只读目录先恢复权限再清理，避免污染临时区
                    try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fx.dirB.path)
                    Fixtures.cleanup(fx.dirA); Fixtures.cleanup(fx.dirB); Fixtures.cleanup(fx.snapDir)
                }
                let leftoverB = URL(fileURLWithPath: fx.urlB.path + ".restore-staging")
                try Data("stale-staging-leftover".utf8).write(to: leftoverB)
                try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: fx.dirB.path)
                do {
                    try fx.mgr.restore(snapshot: fx.snap, to: [("alpha", fx.urlA), ("beta", fx.urlB)])
                    try failTest("staging 预清理失败必须抛错")
                } catch let e as NSError {
                    try expectEqual(e.domain, "SnapshotError", "域应为 SnapshotError")
                    let msg = e.localizedDescription
                    try expectTrue(msg.contains(".restore-staging"),
                                   "staging 失败错误须点名暂存残留路径，实际：\(msg)")
                } catch {
                    try failTest("意外错误类型：\(error)")
                }
                let filesA = try FileManager.default.contentsOfDirectory(at: fx.dirA, includingPropertiesForKeys: nil)
                try expectFalse(filesA.contains { $0.lastPathComponent.hasSuffix(".restore-staging") },
                                "第一目标暂存件必须被清理")
            },

            TestDesc(suite: "RestoreFailClosed", name: "backupCorruptSourceCleansDstResidue") {
                let fx = try makeTwoBookFixture()
                defer { Fixtures.cleanup(fx.dirA); Fixtures.cleanup(fx.dirB); Fixtures.cleanup(fx.snapDir) }
                // 覆写 alpha 目标为非 SQLite 垃圾字节（真坏库文件）
                try Data("definitely not a sqlite database header ______".utf8).write(to: fx.urlA)
                do {
                    try fx.mgr.restore(snapshot: fx.snap, to: [("alpha", fx.urlA), ("beta", fx.urlB)])
                    try failTest("坏库安全网备份必须抛错")
                } catch let e as NSError {
                    try expectEqual(e.domain, "SnapshotError", "域应为 SnapshotError，实际：\(e)")
                } catch {
                    try failTest("意外错误类型：\(error)")
                }
                // 安全网目录：不得残留 alpha 系列半成品（备份失败共用清理基准）
                let subs = try FileManager.default.contentsOfDirectory(at: fx.snapDir, includingPropertiesForKeys: nil)
                var sawSafetyDir = false
                for sub in subs where sub.hasDirectoryPath && sub.lastPathComponent.hasPrefix("pre-restore") {
                    sawSafetyDir = true
                    let files = try FileManager.default.contentsOfDirectory(at: sub, includingPropertiesForKeys: nil)
                    try expectFalse(files.contains { $0.lastPathComponent.hasPrefix("alpha.db") },
                                    "backup 失败后安全网内不得残留目标半成品，实际：\(files)")
                }
                try expectTrue(sawSafetyDir, "安全网目录应已建立（失败发生在安全网阶段）")
                try expectEqual(try readMarker(at: fx.urlB), "v2", "坏库失败不得波及其他目标")
            },

            TestDesc(suite: "RestoreFailClosed", name: "takeSnapshotFailureRemovesPartialDir") {
                let snapDir = Fixtures.makeTempDir("batchd-fc-tsnaps")
                defer { Fixtures.cleanup(snapDir) }
                let srcDir = Fixtures.makeTempDir("batchd-fc-tsnap-src")
                defer { Fixtures.cleanup(srcDir) }
                let urlA = srcDir.appendingPathComponent("alpha.db")
                try makeMarkerDB(at: urlA, value: "v1")
                let missingURL = srcDir.appendingPathComponent("ghost.db")
                let mgr = SnapshotManager(snapshotDir: snapDir,
                                          sources: [("alpha", urlA), ("beta", missingURL)])
                do {
                    _ = try mgr.takeSnapshot()
                    try failTest("第二源缺失必须抛错")
                } catch let e as NSError {
                    try expectEqual(e.domain, "SnapshotError", "域应为 SnapshotError")
                } catch {
                    try failTest("意外错误类型：\(error)")
                }
                let subs = try FileManager.default.contentsOfDirectory(at: snapDir, includingPropertiesForKeys: nil)
                for sub in subs where sub.hasDirectoryPath {
                    let files = try FileManager.default.contentsOfDirectory(at: sub, includingPropertiesForKeys: nil)
                    try expectFalse(files.contains { $0.lastPathComponent == "alpha.db" },
                                    "失败后不得残留可列举的半成品快照目录")
                }
            },

            TestDesc(suite: "RestoreFailClosed", name: "takeSnapshotNeverClobbersExistingSameNameDir") {
                let snapDir = Fixtures.makeTempDir("batchd-fc-uniq")
                defer { Fixtures.cleanup(snapDir) }
                let srcDir = Fixtures.makeTempDir("batchd-fc-uniq-src")
                defer { Fixtures.cleanup(srcDir) }
                let urlA = srcDir.appendingPathComponent("alpha.db")
                try makeMarkerDB(at: urlA, value: "v1")
                let mgr = SnapshotManager(snapshotDir: snapDir, sources: [("alpha", urlA)], keep: 3)
                // 哨兵：以当前秒命名预置目录（若快照同秒发生即构成撞名）
                let f = DateFormatter()
                f.dateFormat = "yyyyMMdd-HHmmss"
                let sentinel = snapDir.appendingPathComponent(f.string(from: Date()))
                try FileManager.default.createDirectory(at: sentinel, withIntermediateDirectories: true)
                try Data("sentinel-do-not-touch".utf8).write(to: sentinel.appendingPathComponent("sentinel.txt"))
                let s1 = try mgr.takeSnapshot()
                let s2 = try mgr.takeSnapshot()
                try expectTrue(s1 != s2, "两次快照目录必须互异")
                try expectTrue(s1.path != sentinel.path && s2.path != sentinel.path,
                               "快照目录绝不能落在既有哨兵目录上（防覆盖基准）")
                let sentinelFiles = try FileManager.default.contentsOfDirectory(at: sentinel, includingPropertiesForKeys: nil)
                try expectTrue(sentinelFiles.contains { $0.lastPathComponent == "sentinel.txt" },
                               "既有同名目录必须原样保留")
                for s in [s1, s2] {
                    let files = try FileManager.default.contentsOfDirectory(at: s, includingPropertiesForKeys: nil)
                    try expectTrue(files.contains { $0.lastPathComponent == "alpha.db" },
                                   "每次快照都须完整产出 \(s.lastPathComponent)")
                }
            },

            TestDesc(suite: "RestoreFailClosed", name: "ensureKeyDuplicateRereadThrowUnifiesToKeychainRead") {
                var loadCount = 0
                AnnotationCrypto.keychainLoadKey = {
                    loadCount += 1
                    if loadCount == 1 { return nil }
                    throw AnnotationCrypto.CryptoError.invalidKeyLength(17)
                }
                AnnotationCrypto.keychainStoreKey = { _ in errSecDuplicateItem }
                defer { resetKeychainHooks() }
                do {
                    _ = try AnnotationCrypto.ensureKey()
                    try failTest("重读抛错必须向上转抛，不得返回临时钥")
                } catch let e as AnnotationCrypto.CryptoError {
                    guard case .keychainRead(_, let reason) = e else {
                        try failTest("判型应统一为 keychainRead，实际：\(e)")
                    }
                    try expectTrue(reason.contains("invalidKeyLength(17)"),
                                   "原始原因须保留在 reason 里，实际：\(reason)")
                    try expectTrue(reason.contains("duplicate"), "reason 须标注 duplicate 场景，实际：\(reason)")
                } catch {
                    try failTest("应抛 CryptoError.keychainRead，实际：\(error)")
                }
            },

            // MARK: - 测试

            TestDesc(suite: "RestoreFailClosed", name: "backupRejectsSymlinkAliasDst") {
                let dir = Fixtures.makeTempDir("batchd-fc-alias")
                defer { Fixtures.cleanup(dir) }
                let snapDir = Fixtures.makeTempDir("batchd-fc-alias-snap")
                defer { Fixtures.cleanup(snapDir) }
                let src = dir.appendingPathComponent("marker.db")
                try makeMarkerDB(at: src, value: "v1")
                let alias = dir.appendingPathComponent("alias.db")
                try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: src)
                let mgr = SnapshotManager(snapshotDir: snapDir, sources: [])
                do {
                    try mgr.backup(src: src.path, dst: alias.path)
                    try failTest("符号链接自指 dst 必须被拒")
                } catch let e as NSError {
                    try expectEqual(e.domain, "SnapshotError", "域应为 SnapshotError")
                    try expectEqual(e.code, 1, "应为别名同文件 code1")
                    try expectTrue(e.localizedDescription.contains("normalized-alias"),
                                   "应命中 normalized-alias 闸，实际：\(e.localizedDescription)")
                } catch {
                    try failTest("意外错误类型：\(error)")
                }
                try expectEqual(try readMarker(at: src), "v1", "源库必须完好无损")
                try expectTrue(FileManager.default.fileExists(atPath: alias.path),
                               "符号链接本身不得被清理动过")
            },

            TestDesc(suite: "RestoreFailClosed", name: "backupRejectsHardlinkAliasDst") {
                let dir = Fixtures.makeTempDir("batchd-fc-hard")
                defer { Fixtures.cleanup(dir) }
                let snapDir = Fixtures.makeTempDir("batchd-fc-hard-snap")
                defer { Fixtures.cleanup(snapDir) }
                let src = dir.appendingPathComponent("marker.db")
                try makeMarkerDB(at: src, value: "v1")
                let hard = dir.appendingPathComponent("hard.db")
                try FileManager.default.linkItem(at: src, to: hard)
                let mgr = SnapshotManager(snapshotDir: snapDir, sources: [])
                do {
                    try mgr.backup(src: src.path, dst: hard.path)
                    try failTest("硬链接别名 dst 必须被拒")
                } catch let e as NSError {
                    try expectEqual(e.domain, "SnapshotError", "域应为 SnapshotError")
                    try expectEqual(e.code, 1, "应为同 inode code1")
                    try expectTrue(e.localizedDescription.contains("same-inode"),
                                   "应命中 same-inode 闸，实际：\(e.localizedDescription)")
                } catch {
                    try failTest("意外错误类型：\(error)")
                }
                try expectEqual(try readMarker(at: src), "v1", "源库必须完好无损")
                try expectTrue(FileManager.default.fileExists(atPath: hard.path),
                               "硬链接目录项不得被清理动过")
            },

            TestDesc(suite: "RestoreFailClosed", name: "restoreThrowsWhenSnapshotSourceIsDirectory") {
                let fx = try makeTwoBookFixture()
                defer { Fixtures.cleanup(fx.dirA); Fixtures.cleanup(fx.dirB); Fixtures.cleanup(fx.snapDir) }
                let betaSnap = fx.snap.appendingPathComponent("beta.db")
                try FileManager.default.removeItem(at: betaSnap)
                try FileManager.default.createDirectory(at: betaSnap, withIntermediateDirectories: false)
                do {
                    try fx.mgr.restore(snapshot: fx.snap, to: [("alpha", fx.urlA), ("beta", fx.urlB)])
                    try failTest("目录冒充快照源必须在前置校验抛错")
                } catch let e as NSError {
                    try expectEqual(e.domain, "SnapshotError", "域应为 SnapshotError")
                    try expectEqual(e.code, 3, "应为源非普通文件 code3")
                    try expectTrue(e.localizedDescription.contains("not a regular file"),
                                   "错误措辞须点名非普通文件，实际：\(e.localizedDescription)")
                } catch {
                    try failTest("意外错误类型：\(error)")
                }
                try FileManager.default.removeItem(at: betaSnap)
                try FileManager.default.createSymbolicLink(at: betaSnap, withDestinationURL: fx.snapDir)
                do {
                    try fx.mgr.restore(snapshot: fx.snap, to: [("alpha", fx.urlA), ("beta", fx.urlB)])
                    try failTest("指向目录的符号链接快照源必须在前置校验抛错")
                } catch let e as NSError {
                    try expectEqual(e.code, 3, "符号链接指目录同样 code3，实际：\(e.localizedDescription)")
                } catch {
                    try failTest("意外错误类型：\(error)")
                }
                try expectEqual(try readMarker(at: fx.urlA), "v2", "前置校验失败目标一必须零接触")
                try expectEqual(try readMarker(at: fx.urlB), "v2", "前置校验失败目标二必须零接触")
                let subs = try FileManager.default.contentsOfDirectory(at: fx.snapDir, includingPropertiesForKeys: nil)
                try expectFalse(subs.contains { $0.lastPathComponent.hasPrefix("pre-restore") },
                                "前置校验先于安全网：失败时不得已建 pre-restore 目录")
            },

            TestDesc(suite: "RestoreFailClosed", name: "restoreRestoresSidecarViaCopyFirstWhenSidecarMoveFails") {
                let fx = try makeTwoBookFixture()
                defer {
                    // 只读目录先恢复权限再清理，避免污染临时区
                    try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fx.dirB.path)
                    Fixtures.cleanup(fx.dirA); Fixtures.cleanup(fx.dirB); Fixtures.cleanup(fx.snapDir)
                }
                let walA = URL(fileURLWithPath: fx.urlA.path + "-wal")
                try Data("WAL-MARKER-A3".utf8).write(to: walA)
                let walB = URL(fileURLWithPath: fx.urlB.path + "-wal")
                try Data("WAL-MARKER-B3".utf8).write(to: walB)
                let betaOrig = try Data(contentsOf: fx.urlB)
                let betaWalOrig = try Data(contentsOf: walB)
                var calls = 0
                SnapshotManager.replaceItemHook = { target, tmp in
                    calls += 1
                    if calls == 1 {
                        _ = try FileManager.default.replaceItemAt(target, withItemAt: tmp)
                        // alpha 位收尾后把 beta 目录转只读：beta 的 sidecar move
                        // （从只读目录移出文件）必然 EPERM，钩子不应被二次调用。
                        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: fx.dirB.path)
                    } else {
                        throw TestFailure(message: "注入：第二库替换不应被触达（sidecar move 应先行失败）")
                    }
                }
                defer { SnapshotManager.replaceItemHook = nil }
                do {
                    try fx.mgr.restore(snapshot: fx.snap, to: [("alpha", fx.urlA), ("beta", fx.urlB)])
                    try failTest("beta sidecar move 失败必须抛错")
                } catch let e as NSError {
                    try expectEqual(e.domain, "SnapshotError", "域应为 SnapshotError")
                    let msg = e.localizedDescription
                    try expectTrue(msg.contains("ROLLBACK FAILED"),
                                   "只读目录下暂存件清不净，失败必须入复合错误，实际：\(msg)")
                } catch {
                    try failTest("意外错误类型：\(error)")
                }
                try expectTrue(try Data(contentsOf: fx.urlB) == betaOrig, "beta 本体字节级未动")
                let walANow = (try? Data(contentsOf: walA)) ?? Data()
                try expectEqual(String(decoding: walANow, as: UTF8.self),
                                "WAL-MARKER-A3",
                                "alpha -wal 必须经「先保留后替换」从安全网副本还原")
                let walBNow = (try? Data(contentsOf: walB)) ?? Data()
                try expectTrue(walBNow == betaWalOrig,
                               "beta -wal 原文未动（move 出只读目录失败，原位保留；现 \(walBNow.count)B 欲 \(betaWalOrig.count)B）")
                try expectEqual(try readMarker(at: fx.urlA), "v2", "alpha 本体必须从安全网回滚回 restore 前态")
                try expectEqual(try readMarker(at: fx.urlB), "v2", "beta 本体零接触")
                let filesA = try FileManager.default.contentsOfDirectory(at: fx.dirA, includingPropertiesForKeys: nil)
                try expectFalse(filesA.contains { $0.lastPathComponent.hasSuffix(".sidecar-restore-tmp") },
                                "成功还原后 tmp 副本必须被消费，不得残留")
                let filesB = try FileManager.default.contentsOfDirectory(at: fx.dirB, includingPropertiesForKeys: nil)
                try expectFalse(filesB.contains { $0.lastPathComponent.hasSuffix(".sidecar-restore-tmp") },
                                "beta 位不得残留 sidecar 还原 tmp（实际：\(filesB)）")
            },
        ]
    }
}
