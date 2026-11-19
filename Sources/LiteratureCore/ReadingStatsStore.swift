import Foundation
import SQLite3

// MARK: - 阅读统计＋页级足迹（reading_sessions / page_footprints 两表）

public final class ReadingStatsStore {
    /// 事件间隔上限（分钟）：超限截断，防挂机虚增。
    public static let defaultCapMinutes: Double = 5

    private let db: SQLiteDatabase
    /// 统一锁执行入口；私有 lock 只保护 anchors。
    private let indexStore: IndexStore
    /// 仅护 `anchors` 读改写的进程内互斥；不充当连接互斥件
    /// （连接互斥由 withSharedConnection 统一承担）。NSLock 不可重入——本
    /// 类内部任何走 withSharedConnection 的辅助函数都不得再取本锁。
    private let lock = NSLock()
    /// 只读副本门（iOS WebDAV 副本打开时统计静默跳过）。
    private let isReadOnly: Bool
    /// 日统计落键所用时区（默认当前系统时区；测试可显式注入固定时区）。
    private let timeZone: TimeZone
    /// 事件锚点（bookID → 上一事件时刻，秒）。
    private var anchors: [String: TimeInterval] = [:]

    public init(indexStore: IndexStore, timeZone: TimeZone = .current) {
        self.db = indexStore.db
        self.indexStore = indexStore
        self.isReadOnly = indexStore.isReadOnlyReplica
        self.timeZone = timeZone
    }

    // MARK: 写路径

    //翻页喂点（共用同一事件点，不双记）：分钟差分＋当日翻页计数
    /// ＋页级足迹 upsert，单次锁定段内一并落库。
    public func recordPageTurn(bookID: String, page: Int, now: TimeInterval,
                               capMinutes: Double = ReadingStatsStore.defaultCapMinutes) throws {
        // 连接互斥在 withSharedConnection 内取得；本锁只护 anchors
        // 读改写与后续整段落库的「上一事件」取值一致性。
        lock.lock(); defer { lock.unlock() }
        try recordEventLocked(bookID: bookID, pageTurn: page, now: now, capMinutes: capMinutes)
    }

    /// 视图出现/消失喂点：只入账分钟差分，不动翻页计数与足迹。
    public func recordActiveEvent(bookID: String, now: TimeInterval,
                                  capMinutes: Double = ReadingStatsStore.defaultCapMinutes) throws {
        lock.lock(); defer { lock.unlock() }
        try recordEventLocked(bookID: bookID, pageTurn: nil, now: now, capMinutes: capMinutes)
    }

    /// 页级足迹 upsert（独立入口，供测试与未来调用点；翻页喂点内部亦走此）。
    /// 同页重复翻到 read_count+1、last_read_at 更新——同页幂等单行。
    public func recordFootprint(bookID: String, page: Int,
                                now: TimeInterval = Date().timeIntervalSince1970) throws {
        lock.lock(); defer { lock.unlock() }
        try indexStore.withSharedConnection {
            guard !isReadOnly else { return }   // 只读纪律：统计写静默 no-op
            try upsertFootprintLocked(bookID: bookID, page: page, now: now)
        }
    }

    private func recordEventLocked(bookID: String, pageTurn: Int?, now: TimeInterval,
                                   capMinutes: Double) throws {
        guard !isReadOnly else { return }   // 只读纪律：统计写静默 no-op
        guard !bookID.isEmpty else { return }
        if let page = pageTurn, page < 1 { return }   // 页 0 = 未落地，不记
        let credit = Self.accumulate(previous: anchors[bookID], now: now, capMinutes: capMinutes)
        anchors[bookID] = now
        let day = Self.dayKey(for: Date(timeIntervalSince1970: now), timeZone: timeZone)
        let pagesDelta = pageTurn != nil ? 1 : 0
        // 纯锚点事件（无可入账分钟且非翻页）不落行——0/0 假行
        //会让 dailyTotals 非 nil、每日卡显「0 分钟，翻页 0 次」，破坏
        // 「无数据显式空态不造数」契约。锚点语义不变（上行已更新锚点）。
        guard credit > 0 || pagesDelta > 0 else { return }
        // 统计行与足迹 upsert 同生共死—— HighlightStore
        // performWriteTransaction 同款显式事务（调用方已持本 store 锁）。此前
        // 两写无包裹：sessions 落库后 footprint upsert 失败会留下「分钟已入账
        // 足迹缺失」的分裂行。
        // 整段改走 IndexStore 统一锁。此前本段只用
        // 本 store 私有锁，而 BEGIN IMMEDIATE 可被 IndexStore 侧在其 lock 内
        // 发起的写从中间插入（`cannot start a transaction within a
        // transaction」）——事务边界现由同一把锁保证。
        try indexStore.withSharedConnection {
            try db.exec("BEGIN IMMEDIATE;")
            do {
                let stmt = try db.prepare("""
                INSERT INTO reading_sessions(book_id, day, minutes, pages, updated_at)
                VALUES(?, ?, ?, ?, ?)
                ON CONFLICT(book_id, day) DO UPDATE SET
                    minutes = minutes + excluded.minutes,
                    pages = pages + excluded.pages,
                    updated_at = excluded.updated_at;
                """)
                try stmt.bindText(1, bookID)
                try stmt.bindText(2, day)
                try stmt.bindDouble(3, credit)
                try stmt.bindInt(4, Int64(pagesDelta))
                try stmt.bindDouble(5, now)
                try stmt.run()
                if let page = pageTurn {
                    try upsertFootprintLocked(bookID: bookID, page: page, now: now)
                }
                try db.exec("COMMIT;")
            } catch {
                db.tryExec("ROLLBACK;")
                throw error
            }
        }
    }

    private func upsertFootprintLocked(bookID: String, page: Int, now: TimeInterval) throws {
        guard !bookID.isEmpty, page >= 1 else { return }
        let stmt = try db.prepare("""
        INSERT INTO page_footprints(book_id, page_number, last_read_at, read_count)
        VALUES(?, ?, ?, 1)
        ON CONFLICT(book_id, page_number) DO UPDATE SET
            read_count = read_count + 1,
            last_read_at = excluded.last_read_at;
        """)
        try stmt.bindText(1, bookID)
        try stmt.bindInt(2, Int64(page))
        try stmt.bindDouble(3, now)
        try stmt.run()
    }

    // MARK: 读路径（只读安全）

    /// 一行日统计。
    public struct DailyStatRow: Equatable, Sendable {
        public let bookID: String
        public let day: String
        public let minutes: Double
        public let pages: Int
        public let updatedAt: Double
    }

    /// 某日逐书统计（按分钟降序）。
    public func stats(day: String) throws -> [DailyStatRow] {
        // 读也经统一锁——读与写共用同一连接，读期间另一侧的写事务不得
        // 被夹进来（只读副本上同样是共享只读句柄）。
        try indexStore.withSharedConnection {
            var out: [DailyStatRow] = []
            let stmt = try db.prepare("""
            SELECT book_id, day, minutes, pages, updated_at
            FROM reading_sessions WHERE day = ? ORDER BY minutes DESC, book_id;
            """)
            try stmt.bindText(1, day)
            while try stmt.step() {
                out.append(DailyStatRow(bookID: stmt.text(0), day: stmt.text(1),
                                        minutes: stmt.double(2), pages: Int(stmt.int(3)),
                                        updatedAt: stmt.double(4)))
            }
            return out
        }
    }

    /// 现有行为：本函数对 `stats(day:)` 求和，
    /// 后者在统一锁入口内**各自**取得/释放 IndexStore 锁——两条读语句之间若
    /// 夹入另一线程的 recordPageTurn，合计可能只含部分并发写入。读数不损坏
    /// （每条 SELECT 都是完整快照），仅在「此刻正有喂点」时可能缺一笔；既有
    /// 测试 twoEventsOnTwoDaysProduceTwoRows 依赖该「先 stats 后 dailyTotals」
    public func dailyTotals(day: String) throws -> DailyTotals? {
        let rows = try stats(day: day)
        guard !rows.isEmpty else { return nil }
        return DailyTotals(minutes: rows.reduce(0) { $0 + $1.minutes },
                           pages: rows.reduce(0) { $0 + $1.pages })
    }

    /// 当日合计值（每日卡统计行；跨书求和）。
    public struct DailyTotals: Equatable, Sendable {
        public var minutes: Double
        public var pages: Int

        public init(minutes: Double, pages: Int) {
            self.minutes = minutes
            self.pages = pages
        }
    }

    /// 一行页级足迹。
    public struct FootprintRow: Equatable, Sendable {
        public let bookID: String
        public let pageNumber: Int
        public let lastReadAt: Double
        public let readCount: Int
    }

    /// 某书全部页级足迹（页号升序；概览九宫格徽标数据源）。
    public func footprints(bookID: String) throws -> [FootprintRow] {
        // 同 stats——读走统一锁。
        try indexStore.withSharedConnection {
            var out: [FootprintRow] = []
            let stmt = try db.prepare("""
            SELECT book_id, page_number, last_read_at, read_count
            FROM page_footprints WHERE book_id = ? ORDER BY page_number;
            """)
            try stmt.bindText(1, bookID)
            while try stmt.step() {
                out.append(FootprintRow(bookID: stmt.text(0), pageNumber: Int(stmt.int(1)),
                                        lastReadAt: stmt.double(2), readCount: Int(stmt.int(3))))
            }
            return out
        }
    }

    // MARK: 纯函数（合成测试直测）

    /// 事件差分计时：与上一事件间隔 ≤ cap 分钟才把间隔入账；首事件只当
    /// 起点不计分钟（previous=nil → 0）；超限截断为 0；时钟回拨（now <
    /// previous）同样截断为 0。间隔落在哪一日，分钟就入哪一日的键（cap
    /// 封顶使跨午夜间隔至多 5 分钟，全部记入新事件当日——基准如实在案）。
    public static func accumulate(previous: TimeInterval?, now: TimeInterval,
                                  capMinutes: Double) -> Double {
        guard let previous else { return 0 }
        let gap = now - previous
        guard gap > 0, gap <= capMinutes * 60 else { return 0 }
        return gap / 60
    }

    /// 本地时区 day 键（YYYY-MM-DD；跨日边界按本地时区落键）。时区可注入，
    /// 测试断言固定即可复现。
    public static func dayKey(for date: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04ld-%02ld-%02ld",
                      parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

//MARK: - 高亮色记忆＋足迹徽标（纯函数，合成测试直测真实现）

extension HighlightColor {
    /// 「上次所用色」记忆解析：合法 rawValue 往返；非法存储值回退 .yellow
    /// （fail-closed）。App 层 @AppStorage 存取走本函数（纯函数单源）。
    public static func memorized(_ rawValue: String) -> HighlightColor {
        HighlightColor(rawValue: rawValue) ?? .yellow
    }
}

/// 概览九宫格足迹徽标判定（页号集合→布尔；空集全不亮/全集全亮/部分逐页——
/// 合成测试覆盖）。PageOverviewView 调用点绑定本函数（纯函数单源）。
public enum PageFootprintBadge {
    public static func isViewed(_ page: Int, footprints: Set<Int>) -> Bool {
        footprints.contains(page)
    }
}

//MARK: - 每日卡整卡文案合成（TTS 朗读输入）

/// 文案合成纯函数：摘录句＋出处＋统计行（空统计不含统计行）。出处行由
/// 调用方预合成（CitationFormatter 属 UI 库，Core 不依赖——引注形制零改动）。
public enum DailyCardComposer {
    /// quote.sentence 为空时返回空串（调用方禁用朗读入口，TTSSpeaker 对空
    /// 文本本就不启动——双向防御）。
    public static func composeDailyCardText(quote: Quote, citation: String?,
                                            stats: ReadingStatsStore.DailyTotals?) -> String {
        let sentence = quote.sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sentence.isEmpty else { return "" }
        var lines: [String] = [sentence]
        if let citation, !citation.isEmpty {
            lines.append("出处：\(citation)")
        }
        if let stats {
            lines.append("今日阅读：\(Self.minutesText(stats.minutes))，翻页 \(stats.pages) 次。")
        }
        return lines.joined(separator: "\n")
    }

    /// 分钟文案（UI 与 TTS 单源）：< 10 分钟保留一位小数（如 3.5 分钟），
    /// ≥ 10 分钟取整（如 42 分钟）——如实数字。取整用 round(.toNearestOrAwayFromZero)
    /// 后格式化（%.0f 是银行家舍入：12.5 → 12，与直觉不符，显式避开）。
    public static func minutesText(_ minutes: Double) -> String {
        if minutes >= 10 {
            let whole = minutes.rounded(.toNearestOrAwayFromZero)
            return String(format: "%.0f 分钟", whole)
        }
        let oneDecimal = String(format: "%.1f", minutes)
        return oneDecimal.hasSuffix(".0")
            ? String(oneDecimal.dropLast(2)) + " 分钟"
            : oneDecimal + " 分钟"
    }
}
