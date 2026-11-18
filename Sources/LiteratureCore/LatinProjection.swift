import Foundation


public enum LatinProjection {
    /// 投影变换（KB 级页文本内存带宽级；大型库回填时的每页热点，零分配
    /// 放大：单次 [UInt8] 缓冲，String(decoding:) 一次成型）。
    public static func transform(_ textNorm: String) -> String {
        var out: [UInt8] = []
        out.reserveCapacity(textNorm.utf8.count / 2)
        var pendingSpace = false
        var lastAppendedWasTokenChar = false
        for b in textNorm.utf8 {
            let isTokenChar = (b >= 0x61 && b <= 0x7A)   // a-z
                || (b >= 0x30 && b <= 0x39)              // 0-9
            if isTokenChar {
                if pendingSpace && lastAppendedWasTokenChar {
                    out.append(0x20)                     // 折叠串分隔（单空格）
                }
                out.append(b)
                pendingSpace = false
                lastAppendedWasTokenChar = true
            } else {
                pendingSpace = true
            }
        }
        return String(decoding: out, as: UTF8.self)
    }
}

// MARK: - pages_wfts 词级虚表维护（meta 键 / 回填 / 断点续跑 / 自愈）

extension IndexStore {
    // meta 键
    //   wfts_ready          — 回填完成置 "1"；缺失/"0" = 词路降级旧路（零风险开关）
    //   wfts_backfill_rowid — 回填断点 checkpoint（批间写；完成保留作记录）
    //   wfts_backfill_heartbeat — 回填在飞心跳（批末刷新；开库续跑钩子见
    //                         60s 内有心跳即让位，防 App/CLI 双进程并发回填）
    //   wfts_built_at       — 回填完成时间戳
    //   wfts_dirty          — 自愈失败置 "1"（词路禁用，查询降级子串路）
    //   wfts_probe_ok_v1    — 健康探针通过节流键（照 fts_probe_ok_v1 先例）

    /// 词路激活开关（路由优先级 4 的判据）：ready 且未脏。
    /// 只读副本分支：meta 不可写但可读——ready 键在 Mac 重建上传时已固化为
    /// "1"，副本上词路照常可用（只读）；脏标一旦固化即永久降级（fail-closed，
    /// 副本无自愈写面）。
    func wftsReadyForWordPathLocked() -> Bool {
        if isReadOnlyReplica {
            // 只读副本：meta 不可写但可读。ready 键在重建上传时已固化为 "1"，
            // 副本上词路可用；脏标不可被清除，置脏即永久降级（fail-closed）。
            return (try? metaValueLocked("wfts_ready")) == "1"
                && (try? metaValueLocked("wfts_dirty")) != "1"
        }
        return (try? metaValueLocked("wfts_ready")) == "1"
            && (try? metaValueLocked("wfts_dirty")) != "1"
    }

    /// 线程安全入口（SearchService.routeTerm 跨类型调用；模内可见不进公开面）。
    func wftsReadyForWordPath() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return wftsReadyForWordPathLocked()
    }

    /// 分批回填 text_latin 并经触发器自动进 pages_wfts。
    @discardableResult
    public func backfillLatinProjection(progress: ((_ done: Int, _ total: Int) -> Void)?) throws -> Int {
        lock.lock(); defer { lock.unlock() }
        return try backfillLatinProjectionLocked(progress: progress)
    }

    /// Caller must hold the lock（ensureWftsReady / migrate 链尾续跑钩子复用；
    /// 跨文件 extension 调用故为模内可见——搬移先例见 IndexStore+migrations.swift 头注）。
    /// Locked helper 只用连接不加锁，与 updateMetadata/upsertBook 既有注同基准。
    func backfillLatinProjectionLocked(progress: ((_ done: Int, _ total: Int) -> Void)?) throws -> Int {
        guard !isReadOnlyReplica else { return 0 }
        if (try? metaValueLocked("wfts_ready")) == "1" { return 0 }
        let wftsExists = hasSqliteObjectLocked(type: "table", name: "pages_wfts")
        guard wftsExists else {
            try setMetaValueLocked("wfts_dirty", "1")
            return 0
        }
        var checkpoint: Int64 = 0
        if let raw = try metaValueLocked("wfts_backfill_rowid"), let v = Int64(raw) {
            checkpoint = v
        }
        // 空索引首启清基：FTS5 external content 对无 docsize 记录的 rowid 发
        // 'delete' 会报 "database disk image is malformed"，而 au 触发器在
        // UPDATE 时先 'delete' 旧值——首轮回填（checkpoint==0）必须先清基，
        // 随后批灌使触发器的 delete 永有对象。续跑（checkpoint>0）禁清基：
        // 已回填行的索引内容在批灌时写入，清基即毁。
        if checkpoint == 0 {
            try db.exec("INSERT INTO pages_wfts(pages_wfts) VALUES('delete-all');")
        }
        var totalRows: Int64 = 0
        let cnt = try db.prepare("SELECT COUNT(*) FROM pages;")
        if try cnt.step() { totalRows = cnt.int(0) }

        let chunk = 20000
        var processed = 0
        let sel = try db.prepare("SELECT rowid, text_norm FROM pages WHERE rowid > ? ORDER BY rowid LIMIT \(chunk);")
        let wftsIns = try db.prepare("INSERT INTO pages_wfts(rowid, text_latin) VALUES (?, ?);")
        let upd = try db.prepare("UPDATE pages SET text_latin = ? WHERE rowid = ?;")
        let t0 = Date()
        while true {
            // 取一批（rowid ASC；checkpoint 严格推进，死循环不可能）。
            try sel.reset(); try sel.clearBindings()
            try sel.bindInt(1, checkpoint)
            var batch: [(Int64, String)] = []
            while try sel.step() {
                batch.append((sel.int(0), sel.text(1)))
            }
            if batch.isEmpty { break }
            try db.exec("BEGIN IMMEDIATE;")
            do {
                var lastRowid: Int64 = checkpoint
                for (rowid, textNorm) in batch {
                    let latin = LatinProjection.transform(textNorm)
                    // 批灌先行：索引持有与即将写入 pages 完全相同的值，使随后
                    // UPDATE 触发的 au 'delete' 永有记录（不撞空索引边界），
                    // 'delete'+重插同值幂等收敛。UPDATE 不能先于批灌。
                    try wftsIns.reset(); try wftsIns.clearBindings()
                    try wftsIns.bindInt(1, rowid)
                    try wftsIns.bindText(2, latin)
                    try wftsIns.run()
                    try upd.reset(); try upd.clearBindings()
                    try upd.bindText(1, latin)
                    try upd.bindInt(2, rowid)
                    try upd.run()
                    lastRowid = rowid
                }
                checkpoint = lastRowid
                // 批间 checkpoint + 心跳：进程退出/崩溃后重开，migrate 链尾的
                // 续跑钩子 / CLI backfill-latin 从此处续跑；心跳供开库钩子
                // 判定「另一进程回填在飞」（60s 窗，让位不并发）。
                try setMetaValueLocked("wfts_backfill_rowid", String(checkpoint))
                try setMetaValueLocked("wfts_backfill_heartbeat", String(Date().timeIntervalSince1970))
                try db.exec("COMMIT;")
            } catch {
                db.tryExec("ROLLBACK;")
                throw error
            }
            processed += batch.count
            progress?(processed, Int(totalRows))
        }
        try db.exec("INSERT INTO pages_wfts(pages_wfts) VALUES('optimize');")
        try setMetaValueLocked("wfts_built_at", String(Int(Date().timeIntervalSince1970)))
        try setMetaValueLocked("wfts_ready", "1")
        FileHandle.standardError.write(Data(
            "[IndexStore] wfts 回填完成: \(processed) 页, \(String(format: "%.1f", Date().timeIntervalSince(t0)))s\n".utf8))
        return processed
    }

    /// 打开时/批末调用：wfts_ready=0 且未在飞 → 从 checkpoint 续跑回填。
    /// 幂等、重入安全（单进程内本类 NSLock 串行；跨进程由 checkpoint 语义
    /// 降级处理——重复处理同一批页为幂等重写）。返回是否有实际回填发生。
    @discardableResult
    public func ensureWftsReady() throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !isReadOnlyReplica else { return false }
        if (try? metaValueLocked("wfts_ready")) == "1" { return false }
        let n = try backfillLatinProjectionLocked(progress: nil)
        return n > 0
    }

    /// wfts 自愈探针（探针本征 O(1)，每次启动可跑；rebuild 才是大操作）：
    /// ready=1 且 pages_wfts 空而 pages 存在非空投影 → 索引与真源脱钩
    /// （外部删除/存储损坏）→ `'rebuild'` 全量重建（external content 真源
    /// = pages.text_latin 列，列在即索引可再造）。失败置 wfts_dirty=1
    /// fail-closed（词路降级子串路），原因记入 meta。
    func selfHealWftsIfNeededLocked() throws {
        guard !isReadOnlyReplica else { return }
        guard (try? metaValueLocked("wfts_ready")) == "1" else { return }
        guard (try? metaValueLocked("wfts_dirty")) != "1" else { return }
        guard hasSqliteObjectLocked(type: "table", name: "pages_wfts") else { return }
        // 节流：探针通过后本启动周期内不重跑（进程级；与 bigram 空表探针
        // 每启动跑一次同价位）。
        func hasRow(_ sql: String) throws -> Bool {
            let stmt = try db.prepare(sql)
            defer { stmt.reset() }
            return try stmt.step()
        }
        let wftsEmpty = try !hasRow("SELECT 1 FROM pages_wfts LIMIT 1;")
        guard wftsEmpty else { return }
        let pagesHaveProjection = try hasRow("SELECT 1 FROM pages WHERE text_latin != '' LIMIT 1;")
        guard pagesHaveProjection else { return }
        do {
            try db.exec("INSERT INTO pages_wfts(pages_wfts) VALUES('rebuild');")
            try setMetaValueLocked("wfts_probe_ok_v1", "1")
            FileHandle.standardError.write(Data("[IndexStore] wfts 自愈: 空索引已 rebuild 自 pages.text_latin\n".utf8))
        } catch {
            try? setMetaValueLocked("wfts_dirty", "1")
            try? setMetaValueLocked("last_wfts_heal_reason", "rebuild 失败: \(error)")
            FileHandle.standardError.write(Data("[IndexStore] wfts 自愈失败（词路降级子串路）: \(error)\n".utf8))
        }
    }

    /// sqlite_master 对象存在性（持锁调用方专用；触发器/表通查）。
    /// 两库分离下按 schema-selective 解析：
    ///   split 形态全文资产只存在于 ft，探针只查 ft.sqlite_master（与查询
    /// 路径解析结果一致）；legacy 形态 SQL 恒指 main。
    /// main∪ft 并查会在 main 侧存在同名影子表时误判存在，
    /// 且调用方（backfill/selfHealWfts）探的对象在 split 态只可能落 ft。
    func hasSqliteObjectLocked(type: String, name: String) -> Bool {
        let schema = fulltextAttached ? "ft" : "main"
        guard let stmt = try? db.prepare("SELECT 1 FROM \(schema).sqlite_master WHERE type = ? AND name = ?;") else {
            return false
        }
        defer { stmt.reset() }
        do {
            try stmt.bindText(1, type)
            try stmt.bindText(2, name)
            return (try stmt.step())
        } catch {
            return false
        }
    }

    /// 词路候选流：FTS5 MATCH 的有序 rowid 单趟物化。
    /// 【为何物化而非跨锁游标】cursor 若交调用方在锁外逐行 step，遍历中途的
    /// 并发写会让 doclist 快照语义不可判定； 同位先例
    /// candidateRowIDsViaFTS 即持锁物化 [Int64]（ORDER BY rowid ASC 严格单调
    /// 契约同款）。单趟 ORDER BY rowid ASC；内存占用约为 8B×候选数。多词项：词项 quoteForFTS 包裹后按 FTS5
    /// 隐式 AND 连接（与现行 AND-of-terms 契约同形）——由调用方组装传入。
    func wordPathCandidateRowIDs(match query: String) throws -> [Int64] {
        lock.lock(); defer { lock.unlock() }
        let stmt = try db.prepare("SELECT rowid FROM pages_wfts WHERE pages_wfts MATCH ? ORDER BY rowid ASC;")
        try stmt.bindText(1, query)
        defer { stmt.reset() }
        var out: [Int64] = []
        while try stmt.step() { out.append(stmt.int(0)) }
        return out
    }

    /// 词路计数/骨架共用的 rowid→book_id 常驻映射线程安全入口。
    /// （ensureRowidToBookIDMappingLocked 为持锁内核；本包装供 SearchService
    /// 跨类型调用——模内可见即可，不进公开面。）
    func rowidToBookIDMappingCached() throws -> [Int64: String] {
        lock.lock(); defer { lock.unlock() }
        return try ensureRowidToBookIDMappingLocked()
    }
}
