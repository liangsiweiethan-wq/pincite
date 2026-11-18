import Foundation

// MARK: - 相似文档推荐（bigram 共现；DEVONthink See Also 交互形态

public struct SimilarBook: Equatable, Identifiable, Sendable {
    public var id: String { bookID }
    public let bookID: String
    public let fileName: String
    public let title: String?          // nil = unknown（不猜）
    public let score: Double
    public let computedAt: Date
}

public final class SimilarBooksEngine: @unchecked Sendable {
    private let store: IndexStore
    /// 排除策略（可空； 非空时策略排除书不进推荐候选）。
    private let policy: ExclusionPolicy?
    private let lock = NSLock()
    /// 进程内缓存：bookID → (结果, 计算时刻)。批末 invalidate 清空。
    private var cache: [String: [SimilarBook]] = [:]
    private var cacheTime: [String: Date] = [:]
    /// df 缓存（bigram → 书数）：跨书复用，显著省 bigram_index 反查。
    private var dfCache: [String: Int] = [:]
    /// 书级缓存有效期：超过即重算（防长会话陈旧；索引完成走 invalidate）。
    private let cacheTTL: TimeInterval

    public init(store: IndexStore, policy: ExclusionPolicy? = nil, cacheTTL: TimeInterval = 600) {
        self.store = store
        self.policy = policy
        self.cacheTTL = cacheTTL
    }

    /// 批末刷新钩子（照 book_native_counts 影子表先例的「批末刷新」位）：
    /// 索引/导入完成后清缓存，下次查询全量重算。
    public func invalidate() {
        lock.lock(); defer { lock.unlock() }
        cache.removeAll()
        dfCache.removeAll()
    }

    /// 相似文档 top-K（默认 5）。未建 bigram_index（LIKE 老库/未迁移）→
    /// 空数组降级不报错；单词书/空文本 → 空数组。
    public func similar(to bookID: String, topK: Int = 5) throws -> [SimilarBook] {
        lock.lock(); defer { lock.unlock() }
        if let hit = cache[bookID], let at = cacheTime[bookID],
           Date().timeIntervalSince(at) < cacheTTL {
            return Array(hit.prefix(topK))
        }
        let result = try computeSimilar(bookID: bookID, topK: max(topK, 5))
        cache[bookID] = result
        cacheTime[bookID] = Date()
        return Array(result.prefix(topK))
    }

    // MARK: 实现（锁内调用）

    private func computeSimilar(bookID: String, topK: Int) throws -> [SimilarBook] {
        // 未建倒排表：降级空数组（不报错——单测基准）。
        guard try store.bigramIndexIsReady() else { return [] }
        let allBooks = try store.allBooks()
        guard let target = allBooks.first(where: { $0.id == bookID }) else { return [] }
        let totalBooks = allBooks.count
        guard totalBooks >= 2 else { return [] }
        // 只推荐「可检索」的书——error 行与策略排除书不进候选
        // （与检索面基准一致；目标书本身仍可发起查询，如实）。
        func recommendable(_ b: IndexStore.BookRow) -> Bool {
            guard b.status == "ok" else { return false }
            if let policy, !policy.allowsBook(realPath: b.realPath, rootPath: b.rootPath, bookID: b.id) {
                return false
            }
            return true
        }
        let recommendableIDs = Set(allBooks.filter(recommendable).map(\.id))

        // 1. 目标书签名（bigram 频次 top-N）。
        let targetTexts = try store.pageNormTextsForSimilarity(bookID: bookID)
        let sigA = Self.topBigrams(texts: targetTexts, limit: Self.signatureSize)
        guard !sigA.isEmpty else { return [] }

        // 2. 签名 bigram 反查页集 → 书集 → df/idf。
        var pageSets: [String: Set<UInt32>] = [:]
        var bookSets: [String: Set<String>] = [:]
        var unionRowIDs = Set<UInt32>()
        for g in sigA {
            if let rows = try store.bigramRowIDs(g) {
                let set = Set(rows)
                pageSets[g] = set
                unionRowIDs.formUnion(set)
            }
        }
        let rowBook = try store.bookIDForRowIDs(Array(unionRowIDs))
        for (g, pages) in pageSets {
            bookSets[g] = Set(pages.compactMap { rowBook[$0] })
        }
        func idf(_ g: String) -> Double {
            if let cached = dfCache[g] { return Self.idf(df: cached, total: totalBooks) }
            let df = bookSets[g]?.count ?? 0
            dfCache[g] = df
            return Self.idf(df: df, total: totalBooks)
        }
        let sigAW = sigA.reduce(0.0) { $0 + idf($1) }
        guard sigAW > 0 else { return [] }

        // 3. 候选书覆盖分 top-K（排除自身）。覆盖分门槛：签名覆盖不足
        //    minCoverageFraction（一成）＝只蹭到个别高频偶合 bigram 的噪声
        // 候选，不进 Jaccard 结算。
        var coverage: [String: Double] = [:]
        for g in sigA {
            guard let books = bookSets[g] else { continue }
            let w = idf(g)
            for b in books where b != bookID && recommendableIDs.contains(b) {
                coverage[b, default: 0] += w
            }
        }
        let candidates = coverage
            .map { ($0.key, $0.value / sigAW) }
            .filter { $0.1 >= Self.minCoverageFraction }
            .sorted { $0.1 > $1.1 }
            .prefix(Self.candidatePool)
        guard !candidates.isEmpty else { return [] }

        var byID: [String: IndexStore.BookRow] = [:]
        for b in allBooks { byID[b.id] = b }
        var out: [SimilarBook] = []
        for (bid, _) in candidates {
            guard let book = byID[bid], recommendableIDs.contains(bid) else { continue }
            let texts = try store.pageNormTextsForSimilarity(bookID: bid)
            let sigB = Self.topBigrams(texts: texts, limit: Self.signatureSize)
            guard !sigB.isEmpty else { continue }
            // sigB 的 idf（dfCache 未命中时现查 bigram_index + 归并）。
            var sigBW = 0.0
            var overlapW = 0.0
            let sigASet = Set(sigA)
            var missing = [String]()
            for g in sigB {
                if dfCache[g] == nil { missing.append(g) }
            }
            if !missing.isEmpty {
                var union = Set<UInt32>()
                var fresh: [String: Set<UInt32>] = [:]
                for g in missing {
                    if let rows = try store.bigramRowIDs(g) {
                        union.formUnion(rows)
                        fresh[g] = Set(rows)
                    }
                }
                let rb = try store.bookIDForRowIDs(Array(union))
                for (g, rows) in fresh {
                    let books = Set(rows.compactMap { rb[$0] })
                    bookSets[g] = books
                    dfCache[g] = books.count
                }
            }
            for g in sigB {
                let w = idf(g)
                sigBW += w
                if sigASet.contains(g) { overlapW += w }
            }
            let denom = sigAW + sigBW - overlapW
            let jaccard = denom > 0 ? overlapW / denom : 0
            out.append(SimilarBook(bookID: book.id, fileName: book.fileName,
                                   title: book.title, score: jaccard,
                                   computedAt: Date()))
        }
        return out.sorted { $0.score > $1.score }.prefix(topK).map { $0 }
    }

    // MARK: 常量与纯函数

    static let signatureSize = 64
    static let candidatePool = 20
    /// 候选门槛：目标书签名被候选书覆盖的 idf 加权比例下限（低于此＝
    /// 偶合 bigram 噪声，不算相似；如实常数，文档随行说明）。
    static let minCoverageFraction = 0.1

    static func idf(df: Int, total: Int) -> Double {
        guard df > 0, total > 0 else { return 0 }
        return log(1.0 + Double(total) / Double(df))
    }

    /// 页 norm 文本 → bigram 频次 top-N（与 IndexStore.bigramize 同款
    /// 相邻二字切片）。
    static func topBigrams(texts: [String], limit: Int) -> [String] {
        var freq: [String: Int] = [:]
        for text in texts {
            let chars = Array(text)
            guard chars.count >= 2 else { continue }
            for i in 0..<(chars.count - 1) {
                freq[String(chars[i]) + String(chars[i + 1]), default: 0] += 1
            }
        }
        return freq.sorted { $0.value > $1.value }.prefix(limit).map(\.key)
    }
}


extension IndexStore {
    /// bigram_index 就绪判定（bidx_built_at 在且未脏；LIKE 老库 false）。
    /// 持锁直读 meta（metaValueLocked private；加锁的 public metaValue
    /// 在此不可用——NSLock 不可重入）。
    func bigramIndexIsReady() throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        var built = false
        var dirty = false
        if let stmt = try? db.prepare("SELECT value FROM meta WHERE key = ?;") {
            try? stmt.bindText(1, "bidx_built_at")
            built = ((try? stmt.step()) == true)
        }
        if let stmt = try? db.prepare("SELECT value FROM meta WHERE key = ?;") {
            try? stmt.bindText(1, "bidx_dirty")
            if (try? stmt.step()) == true { dirty = stmt.text(0) == "1" }
        }
        guard built, !dirty else { return false }
        guard let stmt = try? db.prepare("SELECT 1 FROM bigram_index LIMIT 1;") else { return false }
        _ = try? stmt.step()
        return true
    }

    /// 单 bigram 反查页 rowids（复用: 1532 通道；nil＝表缺失/查询失败）。
    func bigramRowIDs(_ bigram: String) throws -> [UInt32]? {
        lock.lock(); defer { lock.unlock() }
        let stmt = try db.prepare("SELECT rowids FROM bigram_index WHERE bigram = ?;")
        try stmt.bindText(1, bigram)
        guard try stmt.step() else { return [] }   // bigram 不存在＝空集（合法）
        let blob = stmt.blob(0)
        if blob.isEmpty { return [] }
        var out: [UInt32] = []
        out.reserveCapacity(blob.count / 4)
        blob.withUnsafeBytes { raw in
            for i in stride(from: 0, to: raw.count, by: 4) {
                out.append(raw.loadUnaligned(fromByteOffset: i, as: UInt32.self).bigEndian)
            }
        }
        return out
    }

    //rowid → book_id 归并（分块 IN； 候选书集计算用）。
    func bookIDForRowIDs(_ rowIDs: [UInt32]) throws -> [UInt32: String] {
        lock.lock(); defer { lock.unlock() }
        var out: [UInt32: String] = [:]
        let chunkSize = 500
        var start = 0
        let sorted = rowIDs.sorted()
        while start < sorted.count {
            let end = min(start + chunkSize, sorted.count)
            let chunk = sorted[start..<end]
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            guard let stmt = try? db.prepare("SELECT rowid, book_id FROM pages WHERE rowid IN (\(placeholders));") else {
                return out
            }
            for (i, id) in chunk.enumerated() {
                try? stmt.bindInt(Int32(i + 1), Int64(id))
            }
            while (try? stmt.step()) == true {
                out[UInt32(max(0, stmt.int(0)))] = stmt.text(1)
            }
            stmt.reset()
            start = end
        }
        return out
    }

    //某书全部非空 norm 页文本（签名计算用；只读）。
    func pageNormTextsForSimilarity(bookID: String) throws -> [String] {
        lock.lock(); defer { lock.unlock() }
        var out: [String] = []
        let stmt = try db.prepare("SELECT text_norm FROM pages WHERE book_id = ? AND TRIM(text_norm) != '';")
        try stmt.bindText(1, bookID)
        while try stmt.step() { out.append(stmt.text(0)) }
        return out
    }
}
