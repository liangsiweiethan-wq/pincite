import Foundation


/// 算法三档（DDL CHECK 约束同名；rawValue 即库内存储值）。
public enum ClassificationAlgorithm: String, CaseIterable, Sendable {
    /// 词集任一词被 title+author 拼接串 contains（大小写不敏感）。
    case any
    /// 指定字段等值（字段名枚举：title/author；match_text 形如 "title=X"）。
    case exact
    /// realpath/rel_path 目录前缀（路径段边界，防「/Papers/X」误中
    /// 「/Papers」）。
    case prefix_dir

    public var displayName: String {
        switch self {
        case .any: return "任意词包含"
        case .exact: return "字段等值"
        case .prefix_dir: return "目录前缀"
        }
    }
}

/// 规则对象（classification_rules 行的内存形）。
public struct ClassificationRule: Equatable, Identifiable, Sendable {
    public let id: Int64
    public var name: String
    public var matchText: String
    public var algorithm: ClassificationAlgorithm
    public var targetCategory: String
    public var enabled: Bool
    public var position: Int

    public init(id: Int64, name: String, matchText: String,
                algorithm: ClassificationAlgorithm, targetCategory: String,
                enabled: Bool, position: Int) {
        self.id = id
        self.name = name
        self.matchText = matchText
        self.algorithm = algorithm
        self.targetCategory = targetCategory
        self.enabled = enabled
        self.position = position
    }
}

/// 全量重跑回执（状态如实计数：已归类/未归类/禁用跳过/无效规则跳过）。
public struct ClassifyReport: Sendable {
    public var classified: Int
    public var unclassified: Int
    public var disabledSkipped: Int
    public var invalidSkipped: Int
    /// 仅 dry-run 填充（逐书预览，不写表）；正常重跑 = nil（结果落表，
    /// 读出口走 classifications）。
    public var perBook: [(bookID: String, category: String)]?

    public init(classified: Int = 0, unclassified: Int = 0,
                disabledSkipped: Int = 0, invalidSkipped: Int = 0,
                perBook: [(bookID: String, category: String)]? = nil) {
        self.classified = classified
        self.unclassified = unclassified
        self.disabledSkipped = disabledSkipped
        self.invalidSkipped = invalidSkipped
        self.perBook = perBook
    }
}

public final class ClassificationRulesStore {
    private let indexStore: IndexStore
    private let lock = NSLock()

    public init(indexStore: IndexStore) {
        self.indexStore = indexStore
    }

    // MARK: 规则 CRUD（规则对象往返）

    public func rules() throws -> [ClassificationRule] {
        lock.lock(); defer { lock.unlock() }
        let stmt = try indexStore.db.prepare(
            "SELECT id, name, match_text, algorithm, target_category, enabled, position FROM classification_rules ORDER BY position, id;")
        defer { stmt.reset() }
        var out: [ClassificationRule] = []
        while try stmt.step() {
            guard let algo = ClassificationAlgorithm(rawValue: stmt.text(3)) else { continue }
            out.append(ClassificationRule(id: stmt.int(0), name: stmt.text(1),
                                          matchText: stmt.text(2), algorithm: algo,
                                          targetCategory: stmt.text(4),
                                          enabled: stmt.int(5) != 0, position: Int(stmt.int(6))))
        }
        return out
    }

    @discardableResult
    public func addRule(name: String, matchText: String, algorithm: ClassificationAlgorithm,
                        targetCategory: String, enabled: Bool = true,
                        position: Int? = nil) throws -> Int64 {
        lock.lock(); defer { lock.unlock() }
        let pos = position ?? (try? nextPositionLocked()) ?? 0
        let stmt = try indexStore.db.prepare("""
            INSERT INTO classification_rules(name, match_text, algorithm, target_category, enabled, position)
            VALUES(?, ?, ?, ?, ?, ?);
            """)
        defer { stmt.reset() }
        try stmt.bindText(1, name)
        try stmt.bindText(2, matchText)
        try stmt.bindText(3, algorithm.rawValue)
        try stmt.bindText(4, targetCategory)
        try stmt.bindInt(5, enabled ? 1 : 0)
        try stmt.bindInt(6, Int64(pos))
        try stmt.run()
        return stmt.lastInsertRowid
    }

    public func setEnabled(id: Int64, enabled: Bool) throws {
        lock.lock(); defer { lock.unlock() }
        let stmt = try indexStore.db.prepare("UPDATE classification_rules SET enabled = ? WHERE id = ?;")
        defer { stmt.reset() }
        try stmt.bindInt(1, enabled ? 1 : 0)
        try stmt.bindInt(2, id)
        try stmt.run()
    }

    /// 上下移：与相邻规则交换 position（UI 上下移按钮的最小语义）。
    public func moveRule(id: Int64, offset: Int) throws {
        lock.lock(); defer { lock.unlock() }
        let all = try rulesLocked()
        guard let idx = all.firstIndex(where: { $0.id == id }) else { return }
        let target = idx + offset
        guard all.indices.contains(target) else { return }
        try setLocked(position: all[target].position, id: all[idx].id)
        try setLocked(position: all[idx].position, id: all[target].id)
    }

    public func deleteRule(ids: [Int64]) throws {
        lock.lock(); defer { lock.unlock() }
        let stmt = try indexStore.db.prepare("DELETE FROM classification_rules WHERE id = ?;")
        defer { stmt.reset() }
        for id in ids {
            try stmt.bindInt(1, id)
            try stmt.run()
            stmt.reset()
            stmt.clearBindings()
        }
    }

    // MARK: 求值（纯函数，可单测）

    /// 单规则命中判定。返回 true = 该规则命中该书。
    /// NULL 字段不参与、不猜；路径字段总在（NOT NULL）。
    public static func matches(rule: ClassificationRule, book: IndexStore.BookRow) -> Bool {
        switch rule.algorithm {
        case .any:
            let needles = rule.matchText.split(separator: " ").map { $0.lowercased() }
            guard !needles.isEmpty else { return false }
            // 任一字段 NULL 即该字段不参与；全 NULL 不命中。
            var haystackParts: [String] = []
            if let t = book.title { haystackParts.append(t.lowercased()) }
            if let a = book.author { haystackParts.append(a.lowercased()) }
            guard !haystackParts.isEmpty else { return false }
            let haystack = haystackParts.joined(separator: " ")
            return needles.contains { haystack.contains($0) }
        case .exact:
            // match_text 语法 "title=X" / "author=X"（字段名不区分大小写）；
            // 无字段前缀 = 无效规则，调用方跳过计数（不猜字段）。
            guard let (field, value) = exactParts(rule.matchText) else { return false }
            switch field {
            case "title":
                guard let t = book.title else { return false }
                return t.caseInsensitiveCompare(value) == .orderedSame
            default:
                guard let a = book.author else { return false }
                return a.caseInsensitiveCompare(value) == .orderedSame
            }
        case .prefix_dir:
            let prefix = rule.matchText
            guard !prefix.isEmpty else { return false }
            // 路径段边界：prefix 以 "/" 结尾，或候选路径在 prefix 之后紧跟
            // "/"——「/Papers」不得误中「/PapersX/书.pdf」。
            func pathMatches(_ path: String) -> Bool {
                if path.hasPrefix(prefix) {
                    if prefix.hasSuffix("/") { return true }
                    let rest = path.dropFirst(prefix.count)
                    if rest.isEmpty || rest.first == "/" { return true }
                }
                return false
            }
            return pathMatches(book.realPath) || pathMatches(book.relPath)
        }
    }

    /// exact 档 match_text 解析："title=X" / "author=X" → (field, value)；
    /// 其他形态 = nil（无效，不猜字段）。
    static func exactParts(_ matchText: String) -> (field: String, value: String)? {
        guard let eq = matchText.firstIndex(of: "=") else { return nil }
        let field = String(matchText[..<eq]).trimmingCharacters(in: .whitespaces).lowercased()
        guard field == "title" || field == "author" else { return nil }
        let value = String(matchText[matchText.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return nil }
        return (field, value)
    }

    /// 单书归类：enabled 规则按 position 升序先中先得（单分类）。
    /// 返回命中规则；nil = 无命中（未归类）。无效规则（exact 无字段前缀）
    /// 由调用方经 invalidRule(_:) 计数。
    public static func classify(book: IndexStore.BookRow,
                                rules: [ClassificationRule]) -> ClassificationRule? {
        for rule in rules.sorted(by: { ($0.position, $0.id) < ($1.position, $1.id) }) where rule.enabled {
            if matches(rule: rule, book: book) { return rule }
        }
        return nil
    }

    /// exact 档无效规则判定（供 dry-run/重跑如实计数）。
    public static func isInvalidRule(_ rule: ClassificationRule) -> Bool {
        rule.algorithm == .exact && exactParts(rule.matchText) == nil
    }

    // MARK: 全量重跑（两处显式时机调用：CLI 批末 / 设置页按钮）

    /// 遍历 books 逐本 classify：命中写 book_classifications（同书重跑 =
    /// 覆盖 upsert，幂等）；无命中删该书旧行（规则删除后书回未归类桶）。
    public func classifyAll(dryRun: Bool = false) throws -> ClassifyReport {
        lock.lock(); defer { lock.unlock() }
        let active = try rulesLocked()
        let disabled = active.filter { !$0.enabled }.count
        let invalid = active.filter { $0.enabled && ClassificationRulesStore.isInvalidRule($0) }.count
        let usable = active.filter { $0.enabled && !ClassificationRulesStore.isInvalidRule($0) }

        var report = ClassifyReport(disabledSkipped: disabled, invalidSkipped: invalid,
                                    perBook: dryRun ? [] : nil)
        // 快照先行：allBooks 内部自取 IndexStore.lock（不可重入）——
        // 必须在事务取锁之前完成。
        let books = try indexStore.allBooks()
        if dryRun {
            for book in books {
                if let rule = ClassificationRulesStore.classify(book: book, rules: usable) {
                    report.classified += 1
                    report.perBook?.append((book.id, rule.targetCategory))
                } else {
                    report.unclassified += 1
                }
            }
            return report
        }
        let upsert = try indexStore.db.prepare("""
            INSERT INTO book_classifications(book_id, category, rule_id, classified_at)
            VALUES(?, ?, ?, ?)
            ON CONFLICT(book_id) DO UPDATE SET
                category=excluded.category, rule_id=excluded.rule_id,
                classified_at=excluded.classified_at;
            """)
        let delete = try indexStore.db.prepare("DELETE FROM book_classifications WHERE book_id = ?;")
        defer { upsert.reset(); delete.reset() }
        // lock+BEGIN 并用（replacePages 同款）：本事务与其他 store 写互斥，
        // 双方都不可能被对方 ROLLBACK 连坐。
        indexStore.lock.lock()
        defer { indexStore.lock.unlock() }
        try indexStore.db.exec("BEGIN IMMEDIATE;")
        do {
            // 孤儿行回收：books 无外键同哲学的代价，重跑时统一清理。
            try indexStore.db.exec(
                "DELETE FROM book_classifications WHERE book_id NOT IN (SELECT id FROM books);")
            for book in books {
                if let rule = ClassificationRulesStore.classify(book: book, rules: usable) {
                    report.classified += 1
                    try upsert.bindText(1, book.id)
                    try upsert.bindText(2, rule.targetCategory)
                    try upsert.bindInt(3, rule.id)
                    try upsert.bindDouble(4, Date().timeIntervalSince1970)
                    try upsert.run()
                    upsert.reset(); upsert.clearBindings()
                } else {
                    report.unclassified += 1
                    try delete.bindText(1, book.id)
                    try delete.run()
                    delete.reset(); delete.clearBindings()
                }
            }
            try indexStore.db.exec("COMMIT;")
        } catch {
            try? indexStore.db.exec("ROLLBACK;")
            throw error
        }
        return report
    }

    /// 分类结果读取（设置页计数 / CLI JSON 出口）。
    public func classifications() throws -> [(bookID: String, category: String, ruleID: Int64?)] {
        lock.lock(); defer { lock.unlock() }
        let stmt = try indexStore.db.prepare(
            "SELECT book_id, category, rule_id FROM book_classifications ORDER BY book_id;")
        defer { stmt.reset() }
        var out: [(String, String, Int64?)] = []
        while try stmt.step() {
            let rid: Int64? = stmt.intOrNull(2)
            out.append((stmt.text(0), stmt.text(1), rid))
        }
        return out
    }

    /// 未归类计数（「无分类行 = 未归类」天然成桶——catch-all 不落表）。
    /// SQL 差集直算（books LEFT JOIN 分类表）：孤儿行/已删书不再压低
    /// 未归类数（应修；原 `books 总数 − 分类行数` 会被孤儿行失真）。
    public func unclassifiedCount() throws -> Int {
        lock.lock(); defer { lock.unlock() }
        let stmt = try indexStore.db.prepare("""
            SELECT count(*) FROM books b
            LEFT JOIN book_classifications c ON c.book_id = b.id
            WHERE c.book_id IS NULL;
            """)
        defer { stmt.reset() }
        guard try stmt.step() else { return 0 }
        return Int(stmt.int(0))
    }

    // MARK: Internals（调用方已持锁或本方法内自取；与 migrateSchemaV7 同构）

    private func rulesLocked() throws -> [ClassificationRule] {
        let stmt = try indexStore.db.prepare(
            "SELECT id, name, match_text, algorithm, target_category, enabled, position FROM classification_rules ORDER BY position, id;")
        defer { stmt.reset() }
        var out: [ClassificationRule] = []
        while try stmt.step() {
            guard let algo = ClassificationAlgorithm(rawValue: stmt.text(3)) else { continue }
            out.append(ClassificationRule(id: stmt.int(0), name: stmt.text(1),
                                          matchText: stmt.text(2), algorithm: algo,
                                          targetCategory: stmt.text(4),
                                          enabled: stmt.int(5) != 0, position: Int(stmt.int(6))))
        }
        return out
    }

    private func nextPositionLocked() throws -> Int {
        let stmt = try indexStore.db.prepare("SELECT COALESCE(MAX(position) + 1, 0) FROM classification_rules;")
        defer { stmt.reset() }
        return (try stmt.step()) ? Int(stmt.int(0)) : 0
    }

    private func setLocked(position: Int, id: Int64) throws {
        let stmt = try indexStore.db.prepare("UPDATE classification_rules SET position = ? WHERE id = ?;")
        defer { stmt.reset() }
        try stmt.bindInt(1, Int64(position))
        try stmt.bindInt(2, id)
        try stmt.run()
    }
}
