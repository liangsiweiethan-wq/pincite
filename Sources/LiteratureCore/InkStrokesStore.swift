import Foundation
import SQLite3

// MARK: - ink_strokes 自有表
//
// DDL 逐列照子版本键 `ink_strokes_schema_version` 照
// HighlightStore.swift:115 机制（IndexStore 顶层 schema 不动，自有键追踪）。
// append-only 纪律：正常路径只有 INSERT 与墓碑 UPDATE（deleted_at 置值）；
// 物理删除不存在。
// 存放布局（iOS）：与批注同容器独立 annotations.db（AppSupportPaths.
// appDirectory("annotations.db")）；桌面测试注入临时 SQLiteDatabase。
// 与 HighlightStore 同库时：连接 SQLITE_OPEN_FULLMUTEX 语句级串行，
// 两 store 各持自有 NSLock（既有惯例），跨 store 单事务不存在（写入
// 面各自原子）。

/// 一笔已落库（或待落库）的笔迹。points 为页相对坐标 0-1。
public struct InkStroke: Equatable, Codable {
    public var strokeUUID: String
    public var bookID: String
    /// 涂画只在原件视图（DEFAULT 'original'）。
    public var viewSource: String
    /// 原件物理页（1 起；见 docs/PAGE-BASIS.md）。
    public var pageNumber: Int
    public var deviceID: String
    /// Unix 秒。
    public var createdAt: Double
    /// #RRGGBB（复用四色或画笔色）。
    public var color: String
    public var lineWidth: Double
    public var points: [InkPoint]
    /// 墓碑：非 nil = 已删（保留可查）。
    public var deletedAt: Double?

    public init(strokeUUID: String, bookID: String, viewSource: String = "original",
                pageNumber: Int, deviceID: String, createdAt: Double,
                color: String, lineWidth: Double, points: [InkPoint],
                deletedAt: Double? = nil) {
        self.strokeUUID = strokeUUID
        self.bookID = bookID
        self.viewSource = viewSource
        self.pageNumber = pageNumber
        self.deviceID = deviceID
        self.createdAt = createdAt
        self.color = color
        self.lineWidth = lineWidth
        self.points = points
        self.deletedAt = deletedAt
    }
}

public final class InkStrokesStore {
    /// 子版本键（照 HighlightStore.subschemaMetaKey 机制）。
    public static let subschemaMetaKey = "ink_strokes_schema_version"
    /// 本实现对应的子版本。
    public static let subschemaVersion = 1
    /// 涂画视图来源常量（语义对齐 HighlightStore.viewSourceOriginal）。
    public static let viewSourceOriginal = "original"

    /// 单笔点数上限（与 InkGeometry.maxStrokePoints 同源）。
    static let maxPointsPerStroke = InkGeometry.maxStrokePoints

    /// 注入的默认 deviceID 生成器（测试断言固定；生产走 DeviceIdentity）。
    public var deviceIDProvider: () -> String

    private let db: SQLiteDatabase
    private let lock = NSLock()

    /// init internal：SQLiteDatabase 是模内类型（调用方与 Core 同模块——
    /// iOS 单模块直编 / 合成测试 @testable；HighlightStore.init(db:) 同规）。
    init(db: SQLiteDatabase, deviceIDProvider: @escaping () -> String = { DeviceIdentity.deviceID() }) {
        self.db = db
        self.deviceIDProvider = deviceIDProvider
        lock.lock()
        defer { lock.unlock() }
        migrateIfNeededLocked()
    }

    // MARK: DDL / 子版本

    private func migrateIfNeededLocked() {
        // meta 表自建（独立 annotations.db 形态没有 IndexStore 先建 meta）——
        // 子版本键落点；已存在时零差异。
        _ = db.tryExec("CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);")
        _ = db.tryExec("""
        CREATE TABLE IF NOT EXISTS ink_strokes(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            book_id TEXT NOT NULL,
            view_source TEXT NOT NULL DEFAULT 'original',
            page_number INTEGER NOT NULL,
            device_id TEXT NOT NULL,
            created_at REAL NOT NULL,
            color TEXT NOT NULL,
            line_width REAL NOT NULL,
            points TEXT NOT NULL,
            deleted_at REAL,
            stroke_uuid TEXT NOT NULL
        );
        """)
        _ = db.tryExec("CREATE INDEX IF NOT EXISTS idx_ink_strokes_book ON ink_strokes(book_id, page_number);")
        setSubschemaVersionLocked(Self.subschemaVersion)
    }

    private func setSubschemaVersionLocked(_ v: Int) {
        guard let stmt = try? db.prepare(
            "INSERT INTO meta(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value;") else { return }
        try? stmt.bindText(1, Self.subschemaMetaKey)
        try? stmt.bindText(2, String(v))
        try? stmt.run()
    }

    public var storedSubschemaVersion: Int? {
        lock.lock(); defer { lock.unlock() }
        guard let stmt = try? db.prepare("SELECT value FROM meta WHERE key = ?;") else { return nil }
        try? stmt.bindText(1, Self.subschemaMetaKey)
        guard (try? stmt.step()) == true else { return nil }
        return stmt.textOrNull(0).flatMap { Int($0) }
    }

    // MARK: 写路径（append-only）

    /// 校验并写入一笔。stroke_uuid 已存在（幂等键）→ 返回 nil（跳过，
    /// 不抛错——合并引擎按此语义去重）。校验失败抛错（fail-closed）。
    @discardableResult
    public func addStroke(_ stroke: InkStroke) throws -> Int64? {
        try validate(stroke)
        lock.lock(); defer { lock.unlock() }
        if try strokeExistsLocked(stroke.strokeUUID) { return nil }
        return try insertLocked(stroke)
    }

    /// 校验规则（fail-closed；AnnotationMergeEngine 复用同一条）：
    /// uuid/book 非空、页码 ≥1、点数 2…maxPoints、坐标 0-1、线宽 >0、
    /// 单笔 JSON < 4KB、viewSource 归一。
    public func validate(_ stroke: InkStroke) throws {
        guard !stroke.strokeUUID.isEmpty else { throw StoreError("stroke_uuid 为空") }
        guard !stroke.bookID.isEmpty else { throw StoreError("book_id 为空") }
        guard stroke.pageNumber >= 1 else { throw StoreError("页码非法（物理页 1 起）: \(stroke.pageNumber)") }
        guard stroke.points.count >= 2, stroke.points.count <= Self.maxPointsPerStroke else {
            throw StoreError("点数超窗 [2, \(Self.maxPointsPerStroke)]: \(stroke.points.count)")
        }
        for p in stroke.points where p.x < 0 || p.x > 1 || p.y < 0 || p.y > 1 {
            throw StoreError("页相对坐标越界 (0-1): (\(p.x), \(p.y))")
        }
        guard stroke.lineWidth > 0 else { throw StoreError("线宽必须为正") }
        let json = InkGeometry.encodePoints(stroke.points)
        guard json.utf8.count < InkGeometry.maxStrokeJSONBytes else {
            throw StoreError("单笔 JSON 超 \(InkGeometry.maxStrokeJSONBytes)B 预算")
        }
        if stroke.viewSource != Self.viewSourceOriginal { throw StoreError("涂画只在原件视图（view_source='original'）") }
        guard stroke.color.hasPrefix("#"), stroke.color.count == 7 else { throw StoreError("颜色须 #RRGGBB") }
    }

    struct StoreError: Error, CustomStringConvertible {
        let message: String
        init(_ m: String) { message = m }
        var description: String { message }
    }

    private func strokeExistsLocked(_ uuid: String) throws -> Bool {
        let stmt = try db.prepare("SELECT 1 FROM ink_strokes WHERE stroke_uuid = ? LIMIT 1;")
        try stmt.bindText(1, uuid)
        return try stmt.step()
    }

    private func insertLocked(_ stroke: InkStroke) throws -> Int64 {
        let stmt = try db.prepare("""
            INSERT INTO ink_strokes(book_id, view_source, page_number, device_id, created_at,
                                    color, line_width, points, deleted_at, stroke_uuid)
            VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """)
        try stmt.bindText(1, stroke.bookID)
        try stmt.bindText(2, Self.viewSourceOriginal)
        try stmt.bindInt(3, Int64(stroke.pageNumber))
        try stmt.bindText(4, stroke.deviceID)
        try stmt.bindDouble(5, stroke.createdAt)
        try stmt.bindText(6, stroke.color)
        try stmt.bindDouble(7, stroke.lineWidth)
        try stmt.bindText(8, InkGeometry.encodePoints(stroke.points))
        if let d = stroke.deletedAt { try stmt.bindDouble(9, d) } else { try stmt.bindNull(9) }
        try stmt.bindText(10, stroke.strokeUUID)
        try stmt.run()
        return stmt.lastInsertRowid
    }

    /// 橡皮/撤销：整笔墓碑（append-only 天然契合——写 deleted_at，行保留
    /// 可查）。不存在或已墓碑 → false（幂等）。
    @discardableResult
    public func tombstone(strokeUUID: String, at timestamp: Double? = nil) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        let stmt = try db.prepare("""
            UPDATE ink_strokes SET deleted_at = ?
            WHERE stroke_uuid = ? AND deleted_at IS NULL;
            """)
        try stmt.bindDouble(1, timestamp ?? Date().timeIntervalSince1970)
        try stmt.bindText(2, strokeUUID)
        try stmt.run()
        return stmt.changes > 0
    }

    /// 撤销（本会话操作栈回退的落库半边）：补墓碑即删除，撤销 = 移除
    /// 墓碑恢复可见（仅限本设备本会话刚产生的墓碑——调用方管栈）。
    @discardableResult
    public func untombstone(strokeUUID: String) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        let stmt = try db.prepare("UPDATE ink_strokes SET deleted_at = NULL WHERE stroke_uuid = ?;")
        try stmt.bindText(1, strokeUUID)
        try stmt.run()
        return stmt.changes > 0
    }

    // MARK: 读路径

    /// 某书（可选某页）的笔迹。默认只返回未删（活动）笔迹；includeDeleted
    /// = true 时含墓碑行（导出/合并审计用）。同 uuid 多行时取 created_at
    /// 最新一行（合并引擎保证至多一行未墓碑；含墓碑查询用于全量导出）。
    public func strokes(bookID: String, pageNumber: Int? = nil,
                        includeDeleted: Bool = false) throws -> [InkStroke] {
        lock.lock(); defer { lock.unlock() }
        var sql = """
            SELECT stroke_uuid, book_id, view_source, page_number, device_id, created_at,
                   color, line_width, points, deleted_at
            FROM ink_strokes WHERE book_id = ?
            """
        if pageNumber != nil { sql += " AND page_number = ?" }
        sql += " ORDER BY created_at ASC, id ASC;"
        let stmt = try db.prepare(sql)
        try stmt.bindText(1, bookID)
        if let pn = pageNumber { try stmt.bindInt(2, Int64(pn)) }
        var out: [InkStroke] = []
        while try stmt.step() {
            guard let uuid = stmt.textOrNull(0),
                  let pointsJSON = stmt.textOrNull(8),
                  let points = InkGeometry.decodePoints(pointsJSON) else { continue }  // 坏行跳过（fail-closed 不抛）
            let deleted = stmt.textOrNull(9).flatMap { Double($0) }
            if !includeDeleted, deleted != nil { continue }
            let stroke = InkStroke(
                strokeUUID: uuid,
                bookID: stmt.textOrNull(1) ?? bookID,
                viewSource: stmt.textOrNull(2) ?? Self.viewSourceOriginal,
                pageNumber: Int(stmt.int(3)),
                deviceID: stmt.textOrNull(4) ?? "",
                createdAt: stmt.double(5),
                color: stmt.textOrNull(6) ?? "#000000",
                lineWidth: stmt.double(7),
                points: points,
                deletedAt: deleted)
            out.append(stroke)
        }
        // 同 uuid 取 created_at 最新（合并后唯一活动行的保障；含墓碑视图
        // 下同一 uuid 的新旧行都在，展示基准取新者）。
        var latest: [String: InkStroke] = [:]
        var order: [String] = []
        for s in out {
            if latest[s.strokeUUID] == nil { order.append(s.strokeUUID) }
            if let old = latest[s.strokeUUID], old.createdAt > s.createdAt { continue }
            latest[s.strokeUUID] = s
        }
        return order.compactMap { latest[$0] }
    }

    /// 全量行数（含墓碑；导出/测试用）。
    public func totalRowCount() throws -> Int {
        lock.lock(); defer { lock.unlock() }
        let stmt = try db.prepare("SELECT COUNT(*) FROM ink_strokes;")
        guard try stmt.step() else { return 0 }
        return Int(stmt.int(0))
    }
}

// MARK: - UI 状态机纯函数（触控/Pencil 本身无法合成，可测的
// 全部抽进 Core——工具选择↔PKToolPicker 配置映射、笔迹会话 undo/redo 栈。
// iOS 层 AnnotationCanvasView/AnnotationPaletteView 按这里的纯输出配置
// UIKit 侧，macOS 合成测试直接覆盖。）

public enum InkTool: String, Codable, CaseIterable {
    case pen
    case marker
    /// 橡皮：「划掉即擦除」手势语义（Goodnotes 7 一手先例）——橡皮划扫笔本身不落库，划扫路径逐段命中
    /// 测试（InkGeometry.hitTest）整笔墓碑。iOS 侧映射为透明笔收集划扫
    /// 轨迹（AnnotationCanvasView.tool(_:)），Core 不触 UIKit。
    case eraser
}

/// 一次工具选择（常用四色一级 + 全色板抽屉二级的取值形态；PDF Expert
/// 分级）。
public struct InkToolSelection: Equatable, Codable {
    public var colorHex: String   // #RRGGBB
    public var lineWidth: Double
    public var tool: InkTool

    public init(colorHex: String, lineWidth: Double, tool: InkTool) {
        self.colorHex = colorHex
        self.lineWidth = lineWidth
        self.tool = tool
    }

    /// 常用四色一级。琥珀不入选——它是 OCR 来源专用信号色（琥珀零新增
    /// 位点约束），涂画侧用独立画笔色。
    public static let primaryColors = ["#FFDF3E", "#7CE38B", "#8EC9FF", "#FF8A80"]
    /// 笔宽两档（细/粗）。
    public static let lineWidths: [Double] = [2.0, 5.0]

    /// 一级面板默认项（第一色 + 细笔 + pen）。
    public static var paletteDefault: InkToolSelection {
        InkToolSelection(colorHex: primaryColors[0], lineWidth: lineWidths[0], tool: .pen)
    }

    /// PKToolPicker 配置映射（纯函数）：iOS 层据此设 PKToolPicker 的
    /// color/width 与 PKInkType（pen/marker）。返回元组而非 UIKit 类型，
    /// 保持 Core 零 UIKit。eraser 不经 PKToolPicker（划掉即擦除手势语义，
    /// 见 InkTool.eraser 注记）——此处恒 isMarker=false，调用方按 tool 分派。
    public static func toolPickerConfig(_ s: InkToolSelection) -> (colorHex: String, width: Double, isMarker: Bool) {
        (s.colorHex, s.lineWidth, s.tool == .marker)
    }
}

/// 会话操作类别：draw = 新笔落库；erase = 橡皮整笔墓碑。
/// undo/redo 的落库方向随类别相反（撤销画笔 = 补墓碑；撤销擦除 = 解墓碑）。
public enum InkSessionOpKind: String, Codable, Equatable {
    case draw
    case erase
}

/// 会话栈内单条操作（kind + strokeUUID）。
public struct InkSessionOp: Equatable, Codable {
    public var kind: InkSessionOpKind
    public var strokeUUID: String

    public init(kind: InkSessionOpKind, strokeUUID: String) {
        self.kind = kind
        self.strokeUUID = strokeUUID
    }
}

/// 本会话操作栈（undo/redo；「撤销 = 本会话操作栈回退」——栈里是操作
/// （类别+strokeUUID）：撤销 draw = 补墓碑、撤销 erase = 解墓碑；redo 反向。
/// 栈本身不落库，会话内有效）。
public struct InkSessionStack: Equatable {
    private(set) var undoOps: [InkSessionOp] = []
    private(set) var redoOps: [InkSessionOp] = []

    public init() {}

    /// 每笔落库后记录（清空 redo 分支——新操作使 redo 失效，标准语义）。
    /// 旧签名 = draw 类（原语义，保留兼容）。
    public mutating func record(_ strokeUUID: String) {
        record(kind: .draw, strokeUUID: strokeUUID)
    }

    /// 带类别记录：橡皮整笔墓碑记 .erase。
    public mutating func record(kind: InkSessionOpKind, strokeUUID: String) {
        undoOps.append(InkSessionOp(kind: kind, strokeUUID: strokeUUID))
        redoOps.removeAll()
    }

    /// 返回应补墓碑的 uuid（栈空 = nil，不可撤销）。旧签名兼容（只按
    /// uuid 回传；调用方按 draw 语义补墓碑）。
    public mutating func undo() -> String? {
        undoOp()?.strokeUUID
    }

    /// 返回应恢复（移除墓碑）的 uuid（栈空 = nil）。旧签名兼容。
    public mutating func redo() -> String? {
        redoOp()?.strokeUUID
    }

    /// 方向感知撤销：返回应回退的操作——调用方按
    /// kind 分派（draw → tombstone；erase → untombstone）。
    public mutating func undoOp() -> InkSessionOp? {
        guard let op = undoOps.popLast() else { return nil }
        redoOps.append(op)
        return op
    }

    /// 方向感知重做：返回应重放的操作（draw → 解墓碑恢复；erase → 补墓碑）。
    public mutating func redoOp() -> InkSessionOp? {
        guard let op = redoOps.popLast() else { return nil }
        undoOps.append(op)
        return op
    }
}
