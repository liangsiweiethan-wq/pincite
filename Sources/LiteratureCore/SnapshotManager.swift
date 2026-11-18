import Foundation
import SQLite3


public struct SnapshotManager {
    let snapshotDir: URL
    let sources: [(name: String, url: URL)]
    let keep: Int

    // 快照/备份基准
    // sources 恒 [("index", index.db)] —— 两库分离后快照【天然不含】
    // fulltext.db（构建即正确：全文索引库为可再生派生物，不参与快照/
    // 备份；损坏可整库重建＋全量重排队，IndexStore.rebuildFulltextLocked）。
    // 恢复语义自洽性（恢复旧 index.db ＋保留现 fulltext.db 的指纹错位窗口）：
    // 书行回退到快照态、页行较新——runQueued 指纹比对重抽取收敛（写序
    // 纪律覆盖恢复态）；快照后消失的书由孤儿清扫（sweepOrphanFulltext
    // PagesLocked，24h 节流）清出 ft 侧页行。缓存（text-cache/）与快照
    // 目录同理互不参与。

    /// 测试注入点（密闭化说明）：非 nil 时以钩子返回值代真
    /// sqlite3_backup_step(backup, 500)（断言 step 失败路径）；生产恒 nil 走真调用。
    static var backupStepOverride: ((OpaquePointer?, Int32) -> Int32)?
    /// 测试注入点（密闭化说明）：非 nil 时以钩子代默认原子替换逻辑（参数＝
    /// 目标 URL、暂存件 URL，断言替换中途失败回滚）；生产恒 nil 走真调用。
    static var replaceItemHook: ((URL, URL) throws -> Void)?

    // MARK: - 快照目录命名唯一事实源

    /// 快照目录名固定格式 yyyyMMdd-HHmmss 的唯一 formatter 工厂。必须断言
    /// en_US_POSIX：DateFormatter 缺省跟随系统日历（Calendar.current），
    /// 非公历（佛历/和历等）下产出不可解析/错年代目录名——listSnapshots
    /// 按日期解析滤除＝快照面板不可见，cleanup 却照删（「不可见即被清」）。
    /// internal 供 @testable 测试直调（密闭化说明：与 backupStepOverride
    /// 同款缝，生产行为不变）。
    static func makeTimestampFormatter() -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }

    /// restore 安全网目录名前缀（唯一事实源：cleanup 的单独限量清理按此前
    /// 缀识别，与 restore 命名两处不得漂移；保持 'p' 前缀不破坏
    /// listSnapshots 的日期过滤——安全网目录绝不冒充真实快照）。
    static let safetyNetPrefix = "pre-restore-"

    /// 安全网目录单独保留上限（不进真实快照 keep 计数；窗口内供回滚取证）。
    static let safetyNetKeep = 2

    // MARK: - 路径别名/inode 闸

    /// 取文件物身标识（dev+ino）；stat 失败（不存在/无权限）返回 nil。
    /// 硬链接降级处理闸的探测件。
    private static func fileIdentity(atPath path: String) -> (dev: UInt64, ino: UInt64)? {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        return (UInt64(st.st_dev), st.st_ino)
    }

    public init(snapshotDir: URL, sources: [(name: String, url: URL)], keep: Int = 1) {
        self.snapshotDir = snapshotDir
        self.sources = sources
        self.keep = keep
    }

    public func takeSnapshot() throws -> URL {
        let timestamp = Self.makeTimestampFormatter().string(from: Date())
        // 目录名唯一后缀防撞——既有同名路径（同秒二拍/历史残留）
        // 依次尝试 -2/-3…，绝不覆盖、绝不触碰既有目录。
        var dirURL = snapshotDir.appendingPathComponent(timestamp)
        var n = 2
        while FileManager.default.fileExists(atPath: dirURL.path) {
            dirURL = snapshotDir.appendingPathComponent("\(timestamp)-\(n)")
            n += 1
        }
        try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true, attributes: nil)

        do {
            for source in sources {
                let srcPath = source.url.path
                let dstPath = dirURL.appendingPathComponent("\(source.name).db").path
                try backup(src: srcPath, dst: dstPath)
            }
        } catch {
            do {
                try FileManager.default.removeItem(at: dirURL)
            } catch let cleanupError {
                throw NSError(domain: "SnapshotError", code: 6, userInfo: [
                    NSLocalizedDescriptionKey: "takeSnapshot failed: \(error)\nAND partial snapshot dir cleanup failed at \(dirURL.path): \(cleanupError)",
                    NSUnderlyingErrorKey: error,
                ])
            }
            throw error
        }

        try cleanupOldSnapshots(at: snapshotDir, keep: keep)
        return dirURL
    }

    // 密闭化说明 internal 仅为测试直调（路径别名/inode 闸），生产行为不变。
    func backup(src srcPath: String, dst dstPath: String) throws {
        // 自备自份会让失败清理误删源库，入口即拒。
        guard srcPath != dstPath else {
            throw NSError(domain: "SnapshotError", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "backup src and dst must differ: \(srcPath)"])
        }
        let srcResolved = URL(fileURLWithPath: srcPath).resolvingSymlinksInPath().path
        let dstResolved = URL(fileURLWithPath: dstPath).resolvingSymlinksInPath().path
        guard srcResolved != dstResolved else {
            throw NSError(domain: "SnapshotError", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "backup src/dst normalized-alias same file: \(srcResolved)"])
        }
        if let s = Self.fileIdentity(atPath: srcPath),
           let d = Self.fileIdentity(atPath: dstPath),
           s.dev == d.dev, s.ino == d.ino {
            throw NSError(domain: "SnapshotError", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "backup src/dst same-inode (hardlink alias): dev=\(s.dev) ino=\(s.ino)"])
        }
        var srcPtr: OpaquePointer?
        var dstPtr: OpaquePointer?

        // open/init/step/finish 各失败路径共用——关句柄＋清目标
        // 四件套（本体/-wal/-shm/-journal）。只删普通文件绝不碰目录；安全网
        // 复制进来的半成品不外泄。
        func cleanupFailedDst() {
            if let p = srcPtr { sqlite3_close(p) }
            if let p = dstPtr { sqlite3_close(p) }
            srcPtr = nil
            dstPtr = nil
            for suffix in ["", "-wal", "-shm", "-journal"] {
                let path = dstPath + suffix
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue {
                    try? FileManager.default.removeItem(atPath: path)
                }
            }
        }

        let srcRC = sqlite3_open_v2(srcPath, &srcPtr, SQLITE_OPEN_READONLY, nil)
        let dstRC = srcRC == SQLITE_OK ? sqlite3_open(dstPath, &dstPtr) : SQLITE_OK
        guard srcRC == SQLITE_OK, dstRC == SQLITE_OK,
              let backup = sqlite3_backup_init(dstPtr, "main", srcPtr, "main") else {
            let err = NSError(domain: "SnapshotError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to open databases: src=\(srcPath) rc=\(srcRC); dst=\(dstPath) rc=\(dstRC)"])
            cleanupFailedDst()
            throw err
        }

        var rc: Int32 = SQLITE_OK
        while true {
            rc = Self.backupStepOverride.map { $0(backup, 500) } ?? sqlite3_backup_step(backup, 500)
            if rc != SQLITE_OK { break }
        }
        if rc != SQLITE_DONE {
            let msg = String(cString: sqlite3_errmsg(dstPtr))
            sqlite3_backup_finish(backup) // 错误态 finish=回滚目标库半成品，必须调
            cleanupFailedDst()
            throw NSError(domain: "SnapshotError", code: 2, userInfo: [NSLocalizedDescriptionKey: "backup step failed rc=\(rc): \(msg)"])
        }
        // finish 返回值不再忽略——非 OK 视同失败，共用清理抛错。
        let finishRC = sqlite3_backup_finish(backup)
        if finishRC != SQLITE_OK {
            cleanupFailedDst()
            throw NSError(domain: "SnapshotError", code: 2, userInfo: [NSLocalizedDescriptionKey: "backup finish failed rc=\(finishRC)"])
        }
        sqlite3_close(srcPtr)
        sqlite3_close(dstPtr)
    }

    private func cleanupOldSnapshots(at dir: URL, keep: Int) throws {
        let f = Self.makeTimestampFormatter()
        let contents = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
            .filter { $0.hasDirectoryPath }
        let snapshots = contents
            .filter { f.date(from: $0.lastPathComponent) != nil }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for old in snapshots.dropFirst(keep) {
            try FileManager.default.removeItem(at: old)
        }
        let safetyNets = contents
            .filter { $0.lastPathComponent.hasPrefix(Self.safetyNetPrefix) }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for old in safetyNets.dropFirst(Self.safetyNetKeep) {
            try FileManager.default.removeItem(at: old)
        }
    }

    // 目录列举与恢复接口。
    public func listSnapshots() -> [URL] {
        let f = Self.makeTimestampFormatter()
        return ((try? FileManager.default.contentsOfDirectory(at: snapshotDir,
                includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? [])
            .filter { $0.hasDirectoryPath && f.date(from: $0.lastPathComponent) != nil }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    public func restore(snapshot: URL, to: [(name: String, url: URL)]) throws {
        try validateSnapshotSources(snapshot: snapshot, to: to)
        let safety = try createSafetyNet(for: to)
        let staged = try stageSnapshotCopies(snapshot: snapshot, to: to)
        try applyStagedReplacements(staged, safety: safety)
    }

    private func validateSnapshotSources(snapshot: URL, to: [(name: String, url: URL)]) throws {
        for target in to {
            let src = snapshot.appendingPathComponent("\(target.name).db")
            let values = try? src.resourceValues(forKeys: [.isRegularFileKey])
            guard values?.isRegularFile == true else {
                let msg = FileManager.default.fileExists(atPath: src.path)
                    ? "Snapshot source not a regular file: \(src.path)"
                    : "Snapshot source missing: \(src.path)"
                throw NSError(domain: "SnapshotError", code: 3,
                              userInfo: [NSLocalizedDescriptionKey: msg])
            }
        }
    }

    /// fail-closed：先给当前态做安全快照，任一失败即抛错不恢复。
    private func createSafetyNet(for to: [(name: String, url: URL)]) throws -> URL {
        let safety = snapshotDir.appendingPathComponent(
            "\(Self.safetyNetPrefix)\(Self.makeTimestampFormatter().string(from: Date()))-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: safety, withIntermediateDirectories: true)
        for target in to {
            try backup(src: target.url.path,
                       dst: safety.appendingPathComponent("\(target.name).db").path)
        }
        return safety
    }

    /// 暂存阶段「登记先行」——tmp 路径在预清理/复制前先入
    /// attempted，任一项失败时清理面覆盖全部已登记路径（含当前失败项），
    private func stageSnapshotCopies(snapshot: URL, to: [(name: String, url: URL)]) throws
        -> [(name: String, target: URL, tmp: URL)] {
        var staged: [(name: String, target: URL, tmp: URL)] = []
        var attempted: [URL] = []
        do {
            for target in to {
                let tmp = URL(fileURLWithPath: target.url.path + ".restore-staging")
                attempted.append(tmp)
                if FileManager.default.fileExists(atPath: tmp.path) {
                    try FileManager.default.removeItem(at: tmp)
                }
                try FileManager.default.copyItem(at: snapshot.appendingPathComponent("\(target.name).db"), to: tmp)
                staged.append((target.name, target.url, tmp))
            }
        } catch {
            var residue: [String] = []
            for p in attempted {
                try? FileManager.default.removeItem(at: p)
                if FileManager.default.fileExists(atPath: p.path) { residue.append(p.path) }
            }
            if residue.isEmpty { throw error }
            throw NSError(domain: "SnapshotError", code: 5, userInfo: [
                NSLocalizedDescriptionKey: "restore staging failed: \(error); staging cleanup incomplete, residue: \(residue.joined(separator: ", "))",
                NSUnderlyingErrorKey: error,
            ])
        }
        return staged
    }

    /// 替换阶段：目标库 -wal/-shm sidecar 删前先 move 进安全网
    private func applyStagedReplacements(_ staged: [(name: String, target: URL, tmp: URL)],
                                         safety: URL) throws {
        var replaced: [(name: String, url: URL)] = []
        var sidecarsSaved: [(target: URL, suffix: String, savedTo: URL)] = []
        do {
            for s in staged {
                for suffix in ["-wal", "-shm"] {
                    let p = URL(fileURLWithPath: s.target.path + suffix)
                    if FileManager.default.fileExists(atPath: p.path) {
                        let savedTo = safety.appendingPathComponent("\(s.name).db\(suffix)")
                        if FileManager.default.fileExists(atPath: savedTo.path) {
                            try FileManager.default.removeItem(at: savedTo)
                        }
                        try FileManager.default.moveItem(at: p, to: savedTo)
                        sidecarsSaved.append((s.target, suffix, savedTo))
                    }
                }
                if let hook = Self.replaceItemHook {
                    try hook(s.target, s.tmp)
                } else if FileManager.default.fileExists(atPath: s.target.path) {
                    _ = try FileManager.default.replaceItemAt(s.target, withItemAt: s.tmp)
                } else {
                    try FileManager.default.moveItem(at: s.tmp, to: s.target)
                }
                replaced.append((s.name, s.target))
            }
        } catch {
            // 回滚每一步失败一律记录；有任一失败→抛复合错误
            // （restore 失败且回滚失败），不吞不丢；全部成功才重抛原始错误。
            let rollbackFailures = rollbackStagedReplacements(staged: staged, replaced: replaced,
                                                              sidecarsSaved: sidecarsSaved,
                                                              safety: safety)
            if rollbackFailures.isEmpty { throw error }
            throw NSError(domain: "SnapshotError", code: 4, userInfo: [
                NSLocalizedDescriptionKey: "restore failed: \(error)\nAND ROLLBACK FAILED:\n"
                    + rollbackFailures.joined(separator: "\n"),
                NSUnderlyingErrorKey: error,
            ])
        }
    }

    /// 替换失败后的回滚，返回每一步的回滚失败文案（空数组＝回滚干净）。
    /// 回滚顺序：先拷后删——安全网 copy 到 .rollback-tmp 成功才动目标，
    /// copy 失败保持替换态（有库文件好过目标缺失）。
    private func rollbackStagedReplacements(staged: [(name: String, target: URL, tmp: URL)],
                                            replaced: [(name: String, url: URL)],
                                            sidecarsSaved: [(target: URL, suffix: String, savedTo: URL)],
                                            safety: URL) -> [String] {
        var rollbackFailures: [String] = []
        for sc in sidecarsSaved.reversed() {
            let dst = URL(fileURLWithPath: sc.target.path + sc.suffix)
            guard FileManager.default.fileExists(atPath: sc.savedTo.path) else {
                rollbackFailures.append("sidecar restore failed: saved copy missing \(sc.savedTo.path)")
                continue
            }
            let tmp = URL(fileURLWithPath: dst.path + ".sidecar-restore-tmp")
            do {
                try FileManager.default.copyItem(at: sc.savedTo, to: tmp)
            } catch {
                rollbackFailures.append("sidecar restore copy failed \(sc.savedTo.path) -> \(tmp.path): \(error)（安全网保存件原样保留）")
                continue
            }
            do {
                if FileManager.default.fileExists(atPath: dst.path) {
                    try FileManager.default.removeItem(at: dst)
                }
                try FileManager.default.moveItem(at: tmp, to: dst)
            } catch {
                rollbackFailures.append("sidecar restore move failed \(sc.savedTo.path) -> \(dst.path): \(error)（.sidecar-restore-tmp 副本保留供人工介入 \(tmp.path)）")
            }
        }
        for r in replaced.reversed() {
            let safetyDb = safety.appendingPathComponent("\(r.name).db")
            guard FileManager.default.fileExists(atPath: safetyDb.path) else {
                rollbackFailures.append("safety snapshot missing for \(r.name): \(safetyDb.path)（目标保持替换态，未删）")
                continue
            }
            let rollbackTmp = URL(fileURLWithPath: r.url.path + ".rollback-tmp")
            do {
                try FileManager.default.copyItem(at: safetyDb, to: rollbackTmp)
            } catch {
                rollbackFailures.append("safety copy failed \(safetyDb.path) -> \(rollbackTmp.path): \(error)（目标保持替换态，未删）")
                continue
            }
            do {
                if FileManager.default.fileExists(atPath: r.url.path) {
                    try FileManager.default.removeItem(at: r.url)
                }
                try FileManager.default.moveItem(at: rollbackTmp, to: r.url)
            } catch {
                rollbackFailures.append("rollback swap failed at \(r.url.path): \(error)（.rollback-tmp 保留供人工介入）")
            }
        }
        for s in staged {
            if FileManager.default.fileExists(atPath: s.tmp.path) {
                do { try FileManager.default.removeItem(at: s.tmp) }
                catch { rollbackFailures.append("staging tmp cleanup failed \(s.tmp.path): \(error)") }
            }
        }
        return rollbackFailures
    }
}
